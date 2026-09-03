// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface ICompleteSetInternalizationHook {
    struct Market {
        bool registered;
        bool frozen;
        IERC20 collateralToken;
        Currency collateralCurrency;
        bytes32 conditionId;
        Currency yesCurrency;
        Currency noCurrency;
        PoolKey yesPoolKey;
        PoolKey noPoolKey;
        PoolId yesPoolId;
        PoolId noPoolId;
        uint256 yesPositionId;
        uint256 noPositionId;
        bytes yesWrapData;
        bytes noWrapData;
        uint256 freeCollateral;
        uint256 pendingCollateralClaims;
        uint256 yesInventory;
        uint256 noInventory;
        uint256 totalShares;
        uint256 lifetimeSurplus;
    }

    struct PoolBinding {
        bool registered;
        bool isYes;
        bytes32 marketId;
    }

    event MarketRegistered(
        bytes32 indexed marketId,
        bytes32 indexed conditionId,
        PoolId indexed yesPoolId,
        PoolId noPoolId,
        address collateralToken,
        address yesToken,
        address noToken
    );
    event CollateralDeposited(bytes32 indexed marketId, address indexed provider, uint256 amount, uint256 sharesMinted);
    event CollateralWithdrawn(bytes32 indexed marketId, address indexed provider, uint256 amount, uint256 sharesBurned);
    event SyntheticFill(
        bytes32 indexed marketId,
        PoolId indexed targetPoolId,
        address indexed trader,
        bool exactInput,
        uint256 outcomeAmount,
        uint256 complementProceeds,
        uint256 netCollateralCost
    );
    event CollateralClaimsSwept(bytes32 indexed marketId, uint256 amount);
    event SplitArbitrage(bytes32 indexed marketId, uint256 amount, uint256 proceeds, uint256 surplus);
    event MergeArbitrage(bytes32 indexed marketId, uint256 amount, uint256 cost, uint256 surplus);
    event MarketFrozen(bytes32 indexed marketId);
    event MarketRedeemed(bytes32 indexed marketId, uint256 collateralReceived);

    error MarketAlreadyRegistered(bytes32 marketId);
    error MarketNotRegistered(bytes32 marketId);
    error PoolAlreadyBound(PoolId poolId);
    error InvalidOutcomePool(PoolId poolId);
    error ConditionNotBinary(bytes32 conditionId, uint256 outcomeSlotCount);
    error ConditionAlreadyResolved(bytes32 conditionId);
    error ConditionNotYetResolved(bytes32 conditionId);
    error MarketFrozenError(bytes32 marketId);
    error ZeroAmount();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientFreeCollateral(uint256 requested, uint256 available);
    error PendingSettlement();
    error InsufficientEdge(uint256 realized, uint256 required);
    error SlippageExceeded(uint256 actual, uint256 limit);

    function registerMarket(
        PoolKey calldata yesPoolKey,
        PoolKey calldata noPoolKey,
        IERC20 collateralToken,
        bytes32 conditionId,
        string calldata yesName,
        string calldata yesSymbol,
        string calldata noName,
        string calldata noSymbol
    ) external returns (bytes32 marketId);

    function depositCollateral(bytes32 marketId, uint256 amount) external returns (uint256 sharesMinted);
    function withdrawCollateral(bytes32 marketId, uint256 shares) external returns (uint256 amountOut);
    function sweepCollateralClaims(bytes32 marketId) external returns (uint256 amountSwept);
    function executeSplitArbitrage(bytes32 marketId, uint256 amount, uint256 minSurplus)
        external
        returns (uint256 surplus);
    function executeMergeArbitrage(bytes32 marketId, uint256 amount, uint256 maxCost, uint256 minSurplus)
        external
        returns (uint256 surplus);
    function freezeForResolution(bytes32 marketId) external;
    function redeemAfterResolution(bytes32 marketId) external returns (uint256 collateralReceived);
    function getMarket(bytes32 marketId) external view returns (Market memory);
    function getMarketForPool(PoolId poolId) external view returns (Market memory market, PoolBinding memory binding);
    function poolBinding(PoolId poolId) external view returns (PoolBinding memory);
    function sharesOf(bytes32 marketId, address owner) external view returns (uint256);
    function SAFETY_MARGIN_BPS() external view returns (uint256);
}
