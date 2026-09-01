// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "@koreth/v1-core/src/core/ProtocolCore.sol";
import {ACLManager} from "@koreth/v1-core/src/core/ACLManager.sol";
import {PositionManager} from "@koreth/v1-core/src/core/PositionManager.sol";
import {LendingEngine} from "@koreth/v1-core/src/core/LendingEngine.sol";
import {LendingPool} from "@koreth/v1-core/src/markets/LendingPool.sol";
import {InterestRateModel} from "@koreth/v1-core/src/markets/InterestRateModel.sol";
import {LPOracleHub} from "@koreth/v1-core/src/oracle/LPOracleHub.sol";
import {IPositionManager} from "@koreth/v1-core/src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "@koreth/v1-core/src/interfaces/ILPAdapter.sol";
import {ILendingPool} from "@koreth/v1-core/src/interfaces/ILendingPool.sol";
import {RiskManager} from "@koreth/v1-core/src/security/RiskManager.sol";
import {RiskConfig} from "@koreth/v1-core/test/helpers/RiskConfig.sol";
import {LeverageTransformer} from "../../src/LeverageTransformer.sol";
import {MockLPAdapter} from "@koreth/v1-core/test/mocks/MockLPAdapter.sol";
import {TestPools} from "@koreth/v1-core/test/helpers/TestPools.sol";
import {TestPricing} from "@koreth/v1-core/test/helpers/TestPricing.sol";
import {TestSecurity} from "@koreth/v1-core/test/helpers/TestSecurity.sol";
import {MockLPOracle} from "@koreth/v1-core/test/mocks/MockLPOracle.sol";
import {MockSwapRouter} from "@koreth/v1-core/test/mocks/MockSwapRouter.sol";
import {MockERC20} from "@koreth/v1-core/test/mocks/MockERC20.sol";

/// @notice Mock V3 flash pool with fee() for factory verification
contract MockFlashPoolWithFee {
    address public token0;
    address public token1;
    uint24 public fee = 3000;
    uint256 public flashFee = 100;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external {
        if (amount0 > 0) MockERC20(token0).transfer(recipient, amount0);
        if (amount1 > 0) MockERC20(token1).transfer(recipient, amount1);

        uint256 fee0 = amount0 > 0 ? flashFee : 0;
        uint256 fee1 = amount1 > 0 ? flashFee : 0;

        LeverageTransformer(recipient).uniswapV3FlashCallback(fee0, fee1, data);
    }
}

/// @notice Mock V3 factory that maps token pairs to pools
contract MockV3Factory {
    mapping(bytes32 => address) public pools;

    function registerPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[keccak256(abi.encodePacked(tokenA, tokenB, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        address pool = pools[keccak256(abi.encodePacked(tokenA, tokenB, fee))];
        if (pool != address(0)) return pool;
        return pools[keccak256(abi.encodePacked(tokenB, tokenA, fee))];
    }
}

contract LeverageTransformerTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockSwapRouter public swapRouter;
    MockFlashPoolWithFee public flashPool;
    MockV3Factory public v3Factory;
    LeverageTransformer public lt;
    LendingPool public pool;
    RiskManager public riskManager;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public lpToken = makeAddr("lpToken");
    address public borrowAsset;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        weth = new MockERC20("WETH", "WETH", 18);

        // Order tokens consistently
        address t0 = address(usdc) < address(weth) ? address(usdc) : address(weth);
        address t1 = address(usdc) < address(weth) ? address(weth) : address(usdc);

        swapRouter = new MockSwapRouter(address(weth));
        flashPool = new MockFlashPoolWithFee(t0, t1);
        v3Factory = new MockV3Factory();
        v3Factory.registerPool(t0, t1, 3000, address(flashPool));

        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        oracleHub = LPOracleHub(
            address(
                new ERC1967Proxy(address(new LPOracleHub()), abi.encodeCall(LPOracleHub.initialize, (address(core))))
            )
        );
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(new LendingEngine()), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        ILendingPool.PoolConfig memory poolConfig = ILendingPool.PoolConfig({borrowAsset: address(usdc)});
        pool = LendingPool(
            address(
                new ERC1967Proxy(
                    address(new LendingPool()),
                    abi.encodeCall(LendingPool.initialize, (poolConfig, address(irm), address(core)))
                )
            )
        );
        borrowAsset = address(usdc);
        riskManager = new RiskManager(address(core));

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        adapter.setTokenReturns(address(usdc), address(weth));
        oracle = new MockLPOracle();
        oracle.setPrice(100_000e18);

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV3);
        TestPricing.wireStable(core, address(usdc));
        core.registerLendingPool(address(usdc), address(pool));
        core.setRiskManager(address(riskManager));
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        TestSecurity.wireBreaker(core, pm);
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        lt = new LeverageTransformer(address(core), address(pm), address(le), address(swapRouter), address(v3Factory));

        vm.prank(owner);
        aclManager.addTransformer(address(lt));
    }

    // ========== Constructor ==========

    function test_constructor_setsImmutables() public view {
        assertEq(address(lt.core()), address(core));
        assertEq(address(lt.positionManager()), address(pm));
        assertEq(address(lt.lendingEngine()), address(le));
        assertEq(address(lt.swapRouter()), address(swapRouter));
        assertEq(address(lt.v3Factory()), address(v3Factory));
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert("ZERO_ADDRESS");
        new LeverageTransformer(address(0), address(pm), address(le), address(swapRouter), address(v3Factory));
    }

    function test_constructor_revertsNotContract() public {
        vm.expectRevert("NOT_CONTRACT");
        new LeverageTransformer(address(core), address(pm), address(le), address(swapRouter), makeAddr("eoa"));
    }

    // ========== Access Control ==========

    function test_leverageUp_revertsNotPositionManager() public {
        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: 0,
            flashAmount: 1000e18,
            flashLoanPool: address(flashPool),
            swapPath0: "",
            swapPath1: "",
            swap0Portion: 5000,
            minSwapOut0: 0,
            minSwapOut1: 0
        });

        vm.prank(alice);
        vm.expectRevert("ONLY_POSITION_MANAGER");
        lt.leverageUp(params);
    }

    function test_leverageDown_revertsNotPositionManager() public {
        LeverageTransformer.LeverageDownParams memory params = LeverageTransformer.LeverageDownParams({
            positionId: 0,
            flashAmount: 1000e18,
            flashLoanPool: address(flashPool),
            repayAmount: 500e18,
            liquidityToRemove: 1000,
            swapPath0: "",
            swapPath1: "",
            minSwapOut0: 0,
            minSwapOut1: 0
        });

        vm.prank(alice);
        vm.expectRevert("ONLY_POSITION_MANAGER");
        lt.leverageDown(params);
    }

    // ========== Flash Pool Validation ==========

    function test_leverageUp_revertsInvalidFlashPool() public {
        // Deploy a fake pool not registered in factory
        MockFlashPoolWithFee fakePool = new MockFlashPoolWithFee(flashPool.token0(), flashPool.token1());

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: posId,
            flashAmount: 1000e18,
            flashLoanPool: address(fakePool),
            swapPath0: "",
            swapPath1: "",
            swap0Portion: 5000,
            minSwapOut0: 0,
            minSwapOut1: 0
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params);

        vm.prank(alice);
        vm.expectRevert("INVALID_FLASH_POOL");
        pm.transform(posId, address(lt), calldata_);
    }

    function test_leverageUp_revertsZeroFlashPool() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: posId,
            flashAmount: 1000e18,
            flashLoanPool: address(0),
            swapPath0: "",
            swapPath1: "",
            swap0Portion: 5000,
            minSwapOut0: 0,
            minSwapOut1: 0
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params);

        vm.prank(alice);
        vm.expectRevert("ZERO_FLASH_POOL");
        pm.transform(posId, address(lt), calldata_);
    }

    function test_leverageUp_revertsZeroFlash() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: posId,
            flashAmount: 0,
            flashLoanPool: address(flashPool),
            swapPath0: "",
            swapPath1: "",
            swap0Portion: 5000,
            minSwapOut0: 0,
            minSwapOut1: 0
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params);

        vm.prank(alice);
        vm.expectRevert("ZERO_FLASH");
        pm.transform(posId, address(lt), calldata_);
    }

    // ========== Callback Auth ==========

    function test_callback_revertsUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED_CALLBACK");
        lt.uniswapV3FlashCallback(0, 0, "");
    }
}
