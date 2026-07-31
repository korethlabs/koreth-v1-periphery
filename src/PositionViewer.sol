// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PositionManager} from "@koreth/v1-core/src/core/PositionManager.sol";
import {LendingEngine} from "@koreth/v1-core/src/core/LendingEngine.sol";
import {ILendingPool} from "@koreth/v1-core/src/interfaces/ILendingPool.sol";
import {ILPAdapter} from "@koreth/v1-core/src/interfaces/ILPAdapter.sol";
import {ProtocolCore} from "@koreth/v1-core/src/core/ProtocolCore.sol";
import {RiskManager} from "@koreth/v1-core/src/security/RiskManager.sol";

/// @title PositionViewer
/// @notice Read-only view functions for the frontend — batch queries for gas efficiency
contract PositionViewer {
    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;
    LendingEngine public immutable lendingEngine;

    struct PositionView {
        uint256 id;
        address owner;
        address lpToken;
        uint256 tokenId;
        uint256 amount;
        uint8 lpType;
        uint8 status;
        uint256 collateralValue;
        uint256 debt;
        uint256 healthFactor;
        uint256 maxBorrow;
        uint256 availableToBorrow;
    }

    /// @dev Liquidity only. A pool is shared by every collateral type, so it has no lpType and no
    ///      LTV of its own — those moved to CollateralTypeView.
    struct PoolView {
        address borrowAsset;
        address pool;
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 utilization;
        uint256 supplyRateAPR;
        uint256 borrowRateAPR;
    }

    /// @dev Risk params, keyed by collateral type. Orthogonal to the pool: one collateral type can
    ///      back borrows from several pools, and `borrowCap`/`currentBorrows` are USD figures
    ///      aggregated across all of them.
    struct CollateralTypeView {
        uint8 lpType;
        uint256 maxLtv;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 haircut;
        uint256 borrowCap;
        uint256 currentBorrows;
        bool enabled;
    }

    constructor(address _core, address _positionManager, address _lendingEngine) {
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        lendingEngine = LendingEngine(_lendingEngine);
    }

    /// @notice Get all positions for a user with full details
    function getUserPositions(address user) external view returns (PositionView[] memory) {
        uint256[] memory ids = positionManager.getPositionsByOwner(user);
        PositionView[] memory views = new PositionView[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            views[i] = getPositionView(ids[i]);
        }

        return views;
    }

    /// @notice Get detailed view of a single position
    function getPositionView(uint256 positionId) public view returns (PositionView memory view_) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 collateralValue = positionManager.getPositionValue(positionId);
        uint256 debt = lendingEngine.getDebt(positionId);
        uint256 healthFactor = positionManager.getHealthFactor(positionId);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);

        view_ = PositionView({
            id: pos.id,
            owner: pos.owner,
            lpToken: pos.lpToken,
            tokenId: pos.tokenId,
            amount: pos.amount,
            lpType: uint8(pos.lpType),
            status: uint8(pos.status),
            collateralValue: collateralValue,
            debt: debt,
            healthFactor: healthFactor,
            maxBorrow: maxBorrow,
            availableToBorrow: maxBorrow > debt ? maxBorrow - debt : 0
        });
    }

    /// @notice Get liquidity overview for the shared pool of a borrow asset
    function getPoolView(address borrowAsset) external view returns (PoolView memory) {
        address poolAddr = core.pools(borrowAsset);
        require(poolAddr != address(0), "POOL_NOT_FOUND");
        ILendingPool.PoolState memory state = ILendingPool(poolAddr).getPoolState();

        return PoolView({
            borrowAsset: borrowAsset,
            pool: poolAddr,
            totalSupply: state.totalSupply,
            totalBorrow: state.totalBorrow,
            utilization: state.utilization,
            supplyRateAPR: state.supplyRate,
            borrowRateAPR: state.borrowRate
        });
    }

    /// @notice Get risk params and current exposure for a collateral type
    function getCollateralTypeView(ILPAdapter.LPType lpType) external view returns (CollateralTypeView memory) {
        address riskManagerAddr = core.riskManagerAddr();
        // Unset until an admin wires it post-deploy. Without this the call into address(0) reverts
        // with no reason string, which is opaque for a view a frontend hits first.
        require(riskManagerAddr != address(0), "RISK_MANAGER_NOT_SET");
        RiskManager riskManager = RiskManager(riskManagerAddr);
        RiskManager.CollateralConfig memory cfg = riskManager.getCollateralConfig(lpType);

        return CollateralTypeView({
            lpType: uint8(lpType),
            maxLtv: cfg.maxLtv,
            liquidationThreshold: cfg.liquidationThreshold,
            liquidationBonus: cfg.liquidationBonus,
            haircut: cfg.haircut,
            borrowCap: cfg.borrowCap,
            currentBorrows: riskManager.lpTypeCurrentBorrows(lpType),
            enabled: cfg.enabled
        });
    }
}
