// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import "./library/UtilLib.sol";
import "./interfaces/IStaderConfig.sol";
import "./interfaces/ISDIncentiveController.sol";
import "./interfaces/ISDUtilityPool.sol";
import "./interfaces/SDCollateral/ISDCollateral.sol";
import "./interfaces/IPoolUtils.sol";
import "./interfaces/IOperatorRewardsCollector.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract SDUtilityPool is ISDUtilityPool, AccessControlUpgradeable, PausableUpgradeable {
    using Math for uint256;

    uint256 public constant DECIMAL = 1e18;

    uint256 public constant MIN_SD_DELEGATE_LIMIT = 1e15;

    uint256 public constant MIN_SD_WITHDRAW_LIMIT = 1e12;

    uint256 public constant MAX_UTILIZATION_RATE_PER_BLOCK = 95129375951; // 25 % APR

    uint256 public constant MAX_PROTOCOL_FEE = 1e17; // 10%

    // State variables

    /// @notice Percentage of protocol fee expressed in gwei
    uint256 public protocolFee;

    /// @notice Block number that fee was last accrued at
    uint256 public accrualBlockNumber;

    /// @notice Accumulator of the total earned interest rate since start of pool
    uint256 public utilizeIndex;

    /// @notice Total amount of outstanding SD utilized
    uint256 public totalUtilizedSD;

    /// @notice Total amount of protocol fee
    uint256 public accumulatedProtocolFee;

    /// @notice utilization rate per block
    uint256 public utilizationRatePerBlock;

    /// @notice value of cToken supply
    uint256 public cTokenTotalSupply;

    /// @notice upper cap on ETH worth of SD utilized per validator
    uint256 public maxETHWorthOfSDPerValidator;

    /// @notice request ID to be finalized next
    uint256 public nextRequestIdToFinalize;

    /// @notice request ID to be assigned to a next withdraw request
    uint256 public nextRequestId;

    /// @notice amount of SD requested for withdraw
    uint256 public sdRequestedForWithdraw;

    /// @notice batch limit on withdraw requests to be finalized in single txn
    uint256 public finalizationBatchLimit;

    /// @notice amount of SD reserved for claim request
    uint256 public sdReservedForClaim;

    /// @notice minimum block delay between requesting for withdraw and finalization of request
    uint256 public minBlockDelayToFinalizeRequest;

    /// @notice upper cap on user non redeemed withdraw request count
    uint256 public maxNonRedeemedDelegatorRequestCount;

    /// @notice address of staderConfig contract
    IStaderConfig public staderConfig;

    /// @notice risk configuration
    RiskConfig public riskConfig;

    /// @notice chronological collection of liquidations
    OperatorLiquidation[] public liquidations;

    // Mappings
    mapping(address => UtilizerStruct) public override utilizerData;
    mapping(address => uint256) public override delegatorCTokenBalance;
    mapping(address => uint256) public override delegatorWithdrawRequestedCTokenCount;

    mapping(uint256 => DelegatorWithdrawInfo) public override delegatorWithdrawRequests;
    mapping(address => uint256[]) public override requestIdsByDelegatorAddress;
    mapping(address => uint256) public override liquidationIndexByOperator;

    uint256 public conservativeEthPerKey;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _admin, address _staderConfig) external initializer {
        UtilLib.checkNonZeroAddress(_admin);
        UtilLib.checkNonZeroAddress(_staderConfig);
        __AccessControl_init_unchained();
        __Pausable_init();
        staderConfig = IStaderConfig(_staderConfig);
        utilizeIndex = DECIMAL;
        utilizationRatePerBlock = 38051750380; // 10% APR
        protocolFee = 0;
        nextRequestId = 1;
        nextRequestIdToFinalize = 1;
        finalizationBatchLimit = 50;
        accrualBlockNumber = block.number;
        minBlockDelayToFinalizeRequest = 50400; //7 days
        maxNonRedeemedDelegatorRequestCount = 1000;
        maxETHWorthOfSDPerValidator = 1 ether;
        conservativeEthPerKey = 2 ether;
        _updateRiskConfig(70, 30, 5, 50);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        //delegate SD during initialization to avoid price inflation of cTokenShare
        _delegate(1 ether);
        emit UpdatedStaderConfig(_staderConfig);
    }

    /**
     * @notice Sender delegate SD and cToken balance increases for sender
     * @dev Accrues fee whether or not the operation succeeds, unless reverted
     * @param sdAmount The amount of SD token to delegate
     */
    function delegate(uint256 sdAmount) external override whenNotPaused {
        if (sdAmount < MIN_SD_DELEGATE_LIMIT) {
            revert InvalidInput();
        }
        accrueFee();
        ISDIncentiveController(staderConfig.getSDIncentiveController()).updateRewardForAccount(msg.sender);
        _delegate(sdAmount);
    }

    /**
     * @notice auxiliary method to put a withdrawal request, takes in cToken amount as input
     * @dev use this function to withdraw all SD from pool, pass delegatorCTokenBalance in the input for such cases
     * @param _cTokenAmount amount of cToken
     * @return _requestId generated request ID for withdrawal
     */
    function requestWithdraw(uint256 _cTokenAmount) external override whenNotPaused returns (uint256 _requestId) {
        if (_cTokenAmount > delegatorCTokenBalance[msg.sender]) {
            revert InvalidAmountOfWithdraw();
        }
        accrueFee();
        uint256 exchangeRate = _exchangeRateStored();
        delegatorCTokenBalance[msg.sender] -= _cTokenAmount;
        delegatorWithdrawRequestedCTokenCount[msg.sender] += _cTokenAmount;
        uint256 sdRequested = (exchangeRate * _cTokenAmount) / DECIMAL;
        if (sdRequested < MIN_SD_WITHDRAW_LIMIT) {
            revert InvalidInput();
        }
        _requestId = _requestWithdraw(sdRequested, _cTokenAmount);
    }

    /**
     * @notice auxiliary method to put a withdrawal request, takes SD amount as input
     * @dev this function is not recommended to withdraw all balance as due to some elapsed block
     * between calculating getDelegatorLatestSDBalance and then executing this function, some more SD rewards
     * might accumulate, use 'requestWithdraw' function in such case by passing delegatorCTokenBalance in the input
     * @param _sdAmount amount of SD to withdraw
     * @return _requestId generated request ID for withdrawal
     */
    function requestWithdrawWithSDAmount(
        uint256 _sdAmount
    ) external override whenNotPaused returns (uint256 _requestId) {
        if (_sdAmount < MIN_SD_WITHDRAW_LIMIT) {
            revert InvalidInput();
        }
        accrueFee();
        uint256 exchangeRate = _exchangeRateStored();
        uint256 cTokenToReduce = Math.ceilDiv((_sdAmount * DECIMAL), exchangeRate);
        if (cTokenToReduce > delegatorCTokenBalance[msg.sender]) {
            revert InvalidAmountOfWithdraw();
        }
        delegatorCTokenBalance[msg.sender] -= cTokenToReduce;
        delegatorWithdrawRequestedCTokenCount[msg.sender] += cTokenToReduce;
        _requestId = _requestWithdraw(_sdAmount, cTokenToReduce);
    }

    /**
     * @notice finalize delegator's withdraw requests
     */
    function finalizeDelegatorWithdrawalRequest() external override whenNotPaused {
        accrueFee();
        uint256 exchangeRate = _exchangeRateStored();
        uint256 maxRequestIdToFinalize = Math.min(nextRequestId, nextRequestIdToFinalize + finalizationBatchLimit);
        uint256 requestId;
        uint256 sdToReserveToFinalizeRequests;
        for (requestId = nextRequestIdToFinalize; requestId < maxRequestIdToFinalize; ) {
            DelegatorWithdrawInfo memory delegatorWithdrawInfo = delegatorWithdrawRequests[requestId];
            uint256 requiredSD = delegatorWithdrawInfo.sdExpected;
            uint256 amountOfcToken = delegatorWithdrawInfo.amountOfCToken;
            uint256 minSDRequiredToFinalizeRequest = Math.min(requiredSD, (amountOfcToken * exchangeRate) / DECIMAL);
            if (
                (sdToReserveToFinalizeRequests + minSDRequiredToFinalizeRequest + accumulatedProtocolFee >
                    getPoolAvailableSDBalance()) ||
                (delegatorWithdrawInfo.requestBlock + minBlockDelayToFinalizeRequest > block.number)
            ) {
                break;
            }
            ISDIncentiveController(staderConfig.getSDIncentiveController()).updateRewardForAccount(
                delegatorWithdrawInfo.owner
            );
            delegatorWithdrawRequests[requestId].sdFinalized = minSDRequiredToFinalizeRequest;
            sdRequestedForWithdraw -= requiredSD;
            sdToReserveToFinalizeRequests += minSDRequiredToFinalizeRequest;
            delegatorWithdrawRequestedCTokenCount[delegatorWithdrawInfo.owner] -= amountOfcToken;
            cTokenTotalSupply -= amountOfcToken;
            unchecked {
                ++requestId;
            }
        }
        nextRequestIdToFinalize = requestId;
        sdReservedForClaim += sdToReserveToFinalizeRequests;
        emit FinalizedWithdrawRequest(nextRequestIdToFinalize);
    }

    /**
     * @notice transfer the SD of finalized request to recipient and delete the request
     * @param _requestId request id to claim
     */
    function claim(uint256 _requestId) external override whenNotPaused {
        if (_requestId >= nextRequestIdToFinalize) {
            revert RequestIdNotFinalized(_requestId);
        }
        DelegatorWithdrawInfo memory delegatorRequest = delegatorWithdrawRequests[_requestId];
        if (msg.sender != delegatorRequest.owner) {
            revert CallerNotAuthorizedToRedeem();
        }
        uint256 sdToTransfer = delegatorRequest.sdFinalized;
        sdReservedForClaim -= sdToTransfer;
        _deleteRequestId(_requestId);
        ISDIncentiveController(staderConfig.getSDIncentiveController()).claim(msg.sender);
        if (!IERC20(staderConfig.getStaderToken()).transfer(msg.sender, sdToTransfer)) {
            revert SDTransferFailed();
        }
        emit RequestRedeemed(msg.sender, sdToTransfer);
    }

    /**
     * @notice Sender utilizes SD from the pool to add it as collateral to run validators
     * @param utilizeAmount The amount of the SD token to utilize
     */
    function utilize(uint256 utilizeAmount) external override whenNotPaused {
        ISDCollateral sdCollateral = ISDCollateral(staderConfig.getSDCollateral());
        (, , uint256 nonTerminalKeyCount) = sdCollateral.getOperatorInfo(msg.sender);
        uint256 currentUtilizedSDCollateral = sdCollateral.operatorUtilizedSDBalance(msg.sender);
        uint256 maxSDUtilizeValue = nonTerminalKeyCount * sdCollateral.convertETHToSD(maxETHWorthOfSDPerValidator);
        if (currentUtilizedSDCollateral + utilizeAmount > maxSDUtilizeValue) {
            revert SDUtilizeLimitReached();
        }
        accrueFee();
        _utilize(msg.sender, utilizeAmount);
    }

    /**
     * @notice utilize SD from the pool to add it as collateral for `operator` to run validators
     * @dev only permissionless node registry contract can call
     * @param operator address of an ETHx operator
     * @param utilizeAmount The amount of the SD token to utilize
     * @param nonTerminalKeyCount count of operator's non terminal keys
     *
     */
    function utilizeWhileAddingKeys(
        address operator,
        uint256 utilizeAmount,
        uint256 nonTerminalKeyCount
    ) external override whenNotPaused {
        UtilLib.onlyStaderContract(msg.sender, staderConfig, staderConfig.PERMISSIONLESS_NODE_REGISTRY());
        ISDCollateral sdCollateral = ISDCollateral(staderConfig.getSDCollateral());
        uint256 currentUtilizedSDCollateral = sdCollateral.operatorUtilizedSDBalance(operator);
        uint256 maxSDUtilizeValue = nonTerminalKeyCount * sdCollateral.convertETHToSD(maxETHWorthOfSDPerValidator);
        if (currentUtilizedSDCollateral + utilizeAmount > maxSDUtilizeValue) {
            revert SDUtilizeLimitReached();
        }
        accrueFee();
        _utilize(operator, utilizeAmount);
    }

    /**
     * @notice Sender repays their utilized SD, returns actual repayment amount
     * @param repayAmount The amount to repay
     */
    function repay(uint256 repayAmount) external whenNotPaused returns (uint256 repaidAmount, uint256 feePaid) {
        accrueFee();
        (repaidAmount, feePaid) = _repay(msg.sender, repayAmount);
    }

    /**
     * @notice Sender repays on behalf of utilizer, returns actual repayment amount
     * @param repayAmount The amount to repay
     */
    function repayOnBehalf(
        address utilizer,
        uint256 repayAmount
    ) external override whenNotPaused returns (uint256 repaidAmount, uint256 feePaid) {
        accrueFee();
        (repaidAmount, feePaid) = _repay(utilizer, repayAmount);
    }

    /**
     * @notice Sender repays their full utilized SD position, this function is introduce to help
     * utilizer not to worry about calculating exact SD repayment amount for clearing their entire position
     */
    function repayFullAmount() external override whenNotPaused returns (uint256 repaidAmount, uint256 feePaid) {
        accrueFee();
        uint256 accountUtilizedPrev = _utilizerBalanceStoredInternal(msg.sender);
        (repaidAmount, feePaid) = _repay(msg.sender, accountUtilizedPrev);
    }

    /**
     * @notice call to withdraw protocol fee SD
     * @dev only `MANAGER` role can call
     * @param _amount amount of protocol fee in SD to withdraw
     */
    function withdrawProtocolFee(uint256 _amount) external override whenNotPaused {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        accrueFee();
        if (_amount > accumulatedProtocolFee || _amount > getPoolAvailableSDBalance()) {
            revert InvalidWithdrawAmount();
        }
        accumulatedProtocolFee -= _amount;
        if (!IERC20(staderConfig.getStaderToken()).transfer(staderConfig.getStaderTreasury(), _amount)) {
            revert SDTransferFailed();
        }
        emit WithdrawnProtocolFee(_amount);
    }

    /// @notice for max approval to SD collateral contract for spending SD tokens
    function maxApproveSD() external override whenNotPaused {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        address sdCollateral = staderConfig.getSDCollateral();
        UtilLib.checkNonZeroAddress(sdCollateral);
        IERC20(staderConfig.getStaderToken()).approve(sdCollateral, type(uint256).max);
    }

    /**
     * @notice Applies accrued fee to total utilized and protocolFees
     * @dev This calculates fee accrued from the last check pointed block
     *   up to the current block and writes new checkpoint to storage.
     */
    function accrueFee() public override whenNotPaused {
        /* Remember the initial block number */
        uint256 currentBlockNumber = block.number;

        /* Short-circuit accumulating 0 fee */
        if (accrualBlockNumber == currentBlockNumber) {
            return;
        }

        /* Calculate the number of blocks elapsed since the last accrual */
        uint256 blockDelta = currentBlockNumber - accrualBlockNumber;

        /*
         * Calculate the fee accumulated into utilized and totalProtocolFee and the new index:
         *  simpleFeeFactor = utilizationRate * blockDelta
         *  feeAccumulated = simpleFeeFactor * totalUtilizedSD
         *  totalUtilizedSDNew = feeAccumulated + totalUtilizedSD
         *  totalProtocolFeeNew = feeAccumulated * protocolFeeFactor + totalProtocolFee
         *  utilizeIndexNew = simpleFeeFactor * utilizeIndex + utilizeIndex
         */

        uint256 simpleFeeFactor = utilizationRatePerBlock * blockDelta;
        uint256 feeAccumulated = (simpleFeeFactor * totalUtilizedSD) / DECIMAL;
        totalUtilizedSD += feeAccumulated;
        accumulatedProtocolFee += (protocolFee * feeAccumulated) / DECIMAL;
        utilizeIndex += Math.ceilDiv((simpleFeeFactor * utilizeIndex), DECIMAL);

        accrualBlockNumber = currentBlockNumber;

        emit AccruedFees(feeAccumulated, accumulatedProtocolFee, totalUtilizedSD);
    }

    /**
     * @notice Initiates the liquidation process for an account if its health factor is below the required threshold.
     * @dev The function checks the health factor, accrues fees, updates utilized indices, and calculates liquidation amounts.
     *      It's important to note that this liquidation process does not touch the operator's self-bonded SD tokens,
     *      even if they could potentially be used for repayment.
     * @param account The address of the account to be liquidated
     */
    function liquidationCall(address account) external override whenNotPaused {
        if (liquidationIndexByOperator[account] != 0) revert AlreadyLiquidated();

        accrueFee();
        UserData memory userData = getUserData(account);

        if (userData.healthFactor > DECIMAL) {
            revert NotLiquidatable();
        }

        _repay(account, userData.totalInterestSD);

        uint256 totalInterestInEth = ISDCollateral(staderConfig.getSDCollateral()).convertSDToETH(
            userData.totalInterestSD
        );
        uint256 liquidationBonusInEth = (totalInterestInEth * riskConfig.liquidationBonusPercent) / 100;
        uint256 liquidationFeeInEth = (totalInterestInEth * riskConfig.liquidationFeePercent) / 100;
        uint256 totalLiquidationAmountInEth = totalInterestInEth + liquidationBonusInEth + liquidationFeeInEth;

        OperatorLiquidation memory liquidation = OperatorLiquidation({
            totalAmountInEth: totalLiquidationAmountInEth,
            totalBonusInEth: liquidationBonusInEth,
            totalFeeInEth: liquidationFeeInEth,
            isRepaid: false,
            isClaimed: false,
            liquidator: msg.sender
        });
        liquidations.push(liquidation);
        liquidationIndexByOperator[account] = liquidations.length;

        IPoolUtils(staderConfig.getPoolUtils()).processOperatorExit(account, totalLiquidationAmountInEth);

        emit LiquidationCall(
            account,
            totalLiquidationAmountInEth,
            liquidationBonusInEth,
            liquidationFeeInEth,
            msg.sender
        );
    }

    /**
     * @notice function used to clear utilizer's SD interest position in case when protocol does not have any ETH
     * collateral left for SD interest due to all collateral ETH being used as liquidation fee, SD interest in this
     * case will be from the moment of liquidationCall and claiming of liquidation
     * @dev only ADMIN role can call, SD worth of interest is lost from the protocol
     * @dev utilizer utilizedSD balance in SDCollateral contract should be 0
     * @param _utilizer array of utilizer addresses
     */
    function clearUtilizerInterest(address[] calldata _utilizer) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        accrueFee();
        uint256 operatorCount = _utilizer.length;
        for (uint256 i; i < operatorCount; ) {
            address utilizer = _utilizer[i];
            if (ISDCollateral(staderConfig.getSDCollateral()).operatorUtilizedSDBalance(utilizer) != 0) {
                revert OperatorUtilizedSDBalanceNonZero();
            }
            uint256 accountUtilizedPrev = _utilizerBalanceStoredInternal(utilizer);

            utilizerData[utilizer].principal = 0;
            utilizerData[utilizer].utilizeIndex = utilizeIndex;
            totalUtilizedSD = totalUtilizedSD > accountUtilizedPrev ? totalUtilizedSD - accountUtilizedPrev : 0;
            emit ClearedUtilizerInterest(utilizer, accountUtilizedPrev);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice function used to move utilizedSD from SDCollateral to UtilityPool
     * in such a way that utilizedSDBalance in SDCollateral contract becomes 0 and utilizer is left with only SD interest
     * @dev only SDCollateral contract can call
     */
    function repayUtilizedSDBalance(address _utilizer, uint256 amount) external override {
        UtilLib.onlyStaderContract(msg.sender, staderConfig, staderConfig.SD_COLLATERAL());
        accrueFee();

        if (!IERC20(staderConfig.getStaderToken()).transferFrom(msg.sender, address(this), amount)) {
            revert SDTransferFailed();
        }

        uint256 accountUtilizedPrev = _utilizerBalanceStoredInternal(_utilizer);
        utilizerData[_utilizer].principal = accountUtilizedPrev - amount;
        utilizerData[_utilizer].utilizeIndex = utilizeIndex;
        totalUtilizedSD = totalUtilizedSD > amount ? totalUtilizedSD - amount : 0;
        emit RepaidUtilizedSDBalance(_utilizer, amount);
    }

    /**
     * @notice Accrue fee to updated utilizeIndex and then calculate account's utilized balance using the updated utilizeIndex
     * @param account The address whose balance should be calculated after updating utilizeIndex
     * @return The calculated balance
     */
    function utilizerBalanceCurrent(address account) external override returns (uint256) {
        accrueFee();
        return _utilizerBalanceStoredInternal(account);
    }

    /**
     * @notice Finishes the liquidation process
     * @dev Both liquidator and treasury expected amounts should be transferred already from the Operator Reward Collector
     * @param account The operator address
     */
    function completeLiquidation(address account) external override whenNotPaused {
        UtilLib.onlyStaderContract(msg.sender, staderConfig, staderConfig.OPERATOR_REWARD_COLLECTOR());
        if (liquidationIndexByOperator[account] == 0) revert InvalidInput();

        uint256 liquidationIndex = liquidationIndexByOperator[account];
        liquidations[liquidationIndexByOperator[account] - 1].isRepaid = true;
        liquidations[liquidationIndexByOperator[account] - 1].isClaimed = true;
        liquidationIndexByOperator[account] = 0;

        emit CompleteLiquidation(liquidationIndex);
    }

    /**
     * @notice Accrue fee then return the up-to-date exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateCurrent() external override returns (uint256) {
        accrueFee();
        return _exchangeRateStored();
    }

    /**
     * @dev Triggers stopped state.
     * Contract must not be paused
     */
    function pause() external {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        _pause();
    }

    /**
     * @dev Returns to normal state.
     * Contract must be paused
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    //Setters

    /**
     * @notice updates protocol fee factor
     * @dev only `MANAGER` role can call
     * @param _protocolFee value of protocol fee percentage expressed in gwei
     */
    function updateProtocolFee(uint256 _protocolFee) external override {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        if (_protocolFee > MAX_PROTOCOL_FEE) {
            revert InvalidInput();
        }
        accrueFee();
        protocolFee = _protocolFee;
        emit ProtocolFeeFactorUpdated(protocolFee);
    }

    /**
     * @notice updates the utilization rate
     * @dev only `MANAGER` role can call
     * @param _utilizationRatePerBlock new value of utilization rate per block
     */
    function updateUtilizationRatePerBlock(uint256 _utilizationRatePerBlock) external override {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        if (_utilizationRatePerBlock > MAX_UTILIZATION_RATE_PER_BLOCK) {
            revert InvalidInput();
        }
        accrueFee();
        utilizationRatePerBlock = _utilizationRatePerBlock;
        emit UtilizationRatePerBlockUpdated(utilizationRatePerBlock);
    }

    /**
     * @notice updates the maximum ETH worth of SD utilized per validator
     * @dev only `MANAGER` role can call
     * @param _maxETHWorthOfSDPerValidator new value of maximum ETH worth of SD utilized per validator
     */
    function updateMaxETHWorthOfSDPerValidator(uint256 _maxETHWorthOfSDPerValidator) external override {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        maxETHWorthOfSDPerValidator = _maxETHWorthOfSDPerValidator;
        emit UpdatedMaxETHWorthOfSDPerValidator(_maxETHWorthOfSDPerValidator);
    }

    /**
     * @notice updates the batch limit to finalize withdraw request in a single txn
     * @dev only `MANAGER` role can call
     * @param _finalizationBatchLimit new value of batch limit
     */
    function updateFinalizationBatchLimit(uint256 _finalizationBatchLimit) external override {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        finalizationBatchLimit = _finalizationBatchLimit;
        emit UpdatedFinalizationBatchLimit(finalizationBatchLimit);
    }

    /**
     * @notice updates the value of minimum block delay to finalize withdraw requests
     * @dev only `DEFAULT_ADMIN_ROLE` role can call
     * @param _minBlockDelayToFinalizeRequest new value of minBlockDelayToFinalizeRequest
     */
    function updateMinBlockDelayToFinalizeRequest(
        uint256 _minBlockDelayToFinalizeRequest
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        minBlockDelayToFinalizeRequest = _minBlockDelayToFinalizeRequest;
        emit UpdatedMinBlockDelayToFinalizeRequest(minBlockDelayToFinalizeRequest);
    }

    /**
     * @notice updates the value of `maxNonRedeemedDelegatorRequestCount`
     * @dev only `ADMIN` role can call
     * @param _count new count of maxNonRedeemedDelegatorRequest
     */
    function updateMaxNonRedeemedDelegatorRequestCount(uint256 _count) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        maxNonRedeemedDelegatorRequestCount = _count;
        emit UpdatedMaxNonRedeemedDelegatorRequestCount(_count);
    }

    /// @notice updates the address of staderConfig
    function updateStaderConfig(address _staderConfig) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        UtilLib.checkNonZeroAddress(_staderConfig);
        staderConfig = IStaderConfig(_staderConfig);
        emit UpdatedStaderConfig(_staderConfig);
    }

    /// @notice updates the value of conservativeEthPerKey
    /// @dev only `ADMIN` role can call
    /// @param _newEthPerKey new value of conservativeEthPerKey
    function updateConservativeEthPerKey(uint256 _newEthPerKey) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newEthPerKey == 0) revert InvalidInput();
        conservativeEthPerKey = _newEthPerKey;
        emit UpdatedConservativeEthPerKey(_newEthPerKey);
    }

    /**
     * @notice Updates the risk configuration
     * @param liquidationThreshold The new liquidation threshold percent (1 - 100)
     * @param liquidationBonusPercent The new liquidation bonus percent (0 - 100)
     * @param liquidationFeePercent The new liquidation fee percent (0 - 100)
     * @param ltv The new loan-to-value ratio (1 - 100)
     */
    function updateRiskConfig(
        uint256 liquidationThreshold,
        uint256 liquidationBonusPercent,
        uint256 liquidationFeePercent,
        uint256 ltv
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateRiskConfig(liquidationThreshold, liquidationBonusPercent, liquidationFeePercent, ltv);
    }

    //Getters

    /// @notice return the list of ongoing withdraw requestIds for a user
    function getRequestIdsByDelegator(address _delegator) external view override returns (uint256[] memory) {
        return requestIdsByDelegatorAddress[_delegator];
    }

    /**
     * @notice Return the utilized balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function utilizerBalanceStored(address account) external view override returns (uint256) {
        return _utilizerBalanceStoredInternal(account);
    }

    /// @notice Calculates the current delegation rate per block
    function getDelegationRatePerBlock() external view override returns (uint256) {
        uint256 oneMinusProtocolFeeFactor = DECIMAL - protocolFee;
        uint256 rateToPool = (utilizationRatePerBlock * oneMinusProtocolFeeFactor) / DECIMAL;
        return (poolUtilization() * rateToPool) / DECIMAL;
    }

    /**
     * @notice Calculates the exchange rate between SD token and corresponding cToken
     * @dev This function does not accrue fee before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() external view override returns (uint256) {
        return _exchangeRateStored();
    }

    /**
     * @notice view function to get utilizer latest utilized balance
     * @param _utilizer address of the utilizer
     */
    function getUtilizerLatestBalance(address _utilizer) public view override returns (uint256) {
        uint256 currentBlockNumber = block.number;
        uint256 blockDelta = currentBlockNumber - accrualBlockNumber;
        uint256 simpleFeeFactor = utilizationRatePerBlock * blockDelta;
        uint256 utilizeIndexNew = Math.ceilDiv((simpleFeeFactor * utilizeIndex), DECIMAL) + utilizeIndex;
        UtilizerStruct storage utilizeSnapshot = utilizerData[_utilizer];

        if (utilizeSnapshot.principal == 0) {
            return 0;
        }
        return (utilizeSnapshot.principal * utilizeIndexNew) / utilizeSnapshot.utilizeIndex;
    }

    /**
     * @notice view function to get delegator latest SD balance
     * @param _delegator address of the delegator
     */
    function getDelegatorLatestSDBalance(address _delegator) external view override returns (uint256) {
        uint256 latestExchangeRate = getLatestExchangeRate();
        return (latestExchangeRate * delegatorCTokenBalance[_delegator]) / DECIMAL;
    }

    /**
     * @notice view function to get latest exchange rate
     */
    function getLatestExchangeRate() public view override returns (uint256) {
        uint256 currentBlockNumber = block.number;
        uint256 blockDelta = currentBlockNumber - accrualBlockNumber;
        uint256 simpleFeeFactor = utilizationRatePerBlock * blockDelta;
        uint256 feeAccumulated = (simpleFeeFactor * totalUtilizedSD) / DECIMAL;
        uint256 totalUtilizedSDNew = feeAccumulated + totalUtilizedSD;
        uint256 totalProtocolFeeNew = (protocolFee * feeAccumulated) / DECIMAL + accumulatedProtocolFee;
        if (cTokenTotalSupply == 0) {
            return DECIMAL;
        } else {
            uint256 poolBalancePlusUtilizedSDMinusReserves = getPoolAvailableSDBalance() +
                totalUtilizedSDNew -
                totalProtocolFeeNew;
            uint256 exchangeRate = (poolBalancePlusUtilizedSDMinusReserves * DECIMAL) / cTokenTotalSupply;
            return exchangeRate;
        }
    }

    function getPoolAvailableSDBalance() public view override returns (uint256) {
        return IERC20(staderConfig.getStaderToken()).balanceOf(address(this)) - sdReservedForClaim;
    }

    /// @notice Calculates the utilization of the utility pool
    function poolUtilization() public view override returns (uint256) {
        // Utilization is 0 when there are no utilized SD
        if (totalUtilizedSD == 0) {
            return 0;
        }

        return (totalUtilizedSD * DECIMAL) / (getPoolAvailableSDBalance() + totalUtilizedSD - accumulatedProtocolFee);
    }

    /**
     * @notice Calculates and returns the user data for a given account
     * @param account The address whose utilisation should be calculated
     * @return UserData struct containing the user data
     */
    function getUserData(address account) public view override returns (UserData memory) {
        uint256 totalInterestSD = getUtilizerLatestBalance(account) -
            ISDCollateral(staderConfig.getSDCollateral()).operatorUtilizedSDBalance(account);
        uint256 totalCollateralInEth = getOperatorTotalEth(account);
        uint256 totalCollateralInSD = ISDCollateral(staderConfig.getSDCollateral()).convertETHToSD(
            totalCollateralInEth
        );

        uint256 healthFactor = (totalInterestSD == 0)
            ? type(uint256).max
            : (totalCollateralInSD * riskConfig.liquidationThreshold * DECIMAL) / (totalInterestSD * 100);

        return
            UserData(
                totalInterestSD,
                totalCollateralInEth,
                healthFactor,
                liquidationIndexByOperator[account] == 0
                    ? 0
                    : liquidations[liquidationIndexByOperator[account] - 1].totalAmountInEth
            );
    }

    /**
     * @notice
     * @param operator Calculates and returns the conservative estimate of the total Ether (ETH) bonded by a given operator
     *                 plus non claimed ETH from rewards collector.
     * @return totalEth The total ETH bonded by the operator
     */
    function getOperatorTotalEth(address operator) public view returns (uint256) {
        (, , uint256 nonTerminalKeys) = ISDCollateral(staderConfig.getSDCollateral()).getOperatorInfo(operator);
        uint256 nonClaimedEth = IOperatorRewardsCollector(staderConfig.getOperatorRewardsCollector()).getBalance(
            operator
        );

        // The actual bonded ETH per non-terminal key is 4 ETH on the beacon chain.
        // However, for a conservative estimate in our calculations, we use conservativeEthPerKey (2 ETH).
        // This conservative approach accounts for potential slashing risks and withdrawal delays
        // associated with ETH staking on the beacon chain.
        return nonTerminalKeys * conservativeEthPerKey + nonClaimedEth;
    }

    /// @notice Returns the liquidation data for a given operator
    ///         If the operator is not liquidated, the function returns an empty OperatorLiquidation struct
    function getOperatorLiquidation(address account) external view override returns (OperatorLiquidation memory) {
        if (liquidationIndexByOperator[account] == 0) return OperatorLiquidation(0, 0, 0, false, false, address(0));
        return liquidations[liquidationIndexByOperator[account] - 1];
    }

    /// @notice Returns the liquidation threshold percent
    function getLiquidationThreshold() external view returns (uint256) {
        return (riskConfig.liquidationThreshold);
    }

    /**
     * @dev Assumes fee has already been accrued up to the current block
     * @param sdAmount The amount of the SD token to delegate
     */
    function _delegate(uint256 sdAmount) internal {
        uint256 exchangeRate = _exchangeRateStored();

        if (!IERC20(staderConfig.getStaderToken()).transferFrom(msg.sender, address(this), sdAmount)) {
            revert SDTransferFailed();
        }
        uint256 cTokenShares = (sdAmount * DECIMAL) / exchangeRate;
        delegatorCTokenBalance[msg.sender] += cTokenShares;
        cTokenTotalSupply += cTokenShares;

        emit Delegated(msg.sender, sdAmount, cTokenShares);
    }

    function _requestWithdraw(uint256 _sdAmountToWithdraw, uint256 cTokenToBurn) internal returns (uint256) {
        if (requestIdsByDelegatorAddress[msg.sender].length + 1 > maxNonRedeemedDelegatorRequestCount) {
            revert MaxLimitOnWithdrawRequestCountReached();
        }
        sdRequestedForWithdraw += _sdAmountToWithdraw;
        delegatorWithdrawRequests[nextRequestId] = DelegatorWithdrawInfo(
            msg.sender,
            cTokenToBurn,
            _sdAmountToWithdraw,
            0,
            block.number
        );
        requestIdsByDelegatorAddress[msg.sender].push(nextRequestId);
        emit WithdrawRequestReceived(msg.sender, nextRequestId, _sdAmountToWithdraw);
        nextRequestId++;
        return nextRequestId - 1;
    }

    function _utilize(address utilizer, uint256 utilizeAmount) internal {
        if (liquidationIndexByOperator[utilizer] != 0) revert AlreadyLiquidated();
        UserData memory userData = getUserData(utilizer);

        if (userData.healthFactor <= DECIMAL) {
            revert UnHealthyPosition();
        }
        if (getPoolAvailableSDBalance() < utilizeAmount + sdRequestedForWithdraw + accumulatedProtocolFee) {
            revert InsufficientPoolBalance();
        }
        uint256 accountUtilizedPrev = _utilizerBalanceStoredInternal(utilizer);

        utilizerData[utilizer].principal = accountUtilizedPrev + utilizeAmount;
        utilizerData[utilizer].utilizeIndex = utilizeIndex;
        totalUtilizedSD += utilizeAmount;
        ISDCollateral(staderConfig.getSDCollateral()).depositSDFromUtilityPool(utilizer, utilizeAmount);
        emit SDUtilized(utilizer, utilizeAmount);
    }

    function _repay(
        address utilizer,
        uint256 repayAmount
    ) internal returns (uint256 repayAmountFinal, uint256 feePaid) {
        /* We fetch the amount the utilizer owes, with accumulated fee */
        uint256 accountUtilizedPrev = _utilizerBalanceStoredInternal(utilizer);

        repayAmountFinal = (repayAmount == type(uint256).max || repayAmount > accountUtilizedPrev)
            ? accountUtilizedPrev
            : repayAmount;

        if (!IERC20(staderConfig.getStaderToken()).transferFrom(msg.sender, address(this), repayAmountFinal)) {
            revert SDTransferFailed();
        }
        uint256 feeAccrued = accountUtilizedPrev -
            ISDCollateral(staderConfig.getSDCollateral()).operatorUtilizedSDBalance(utilizer);
        if (!staderConfig.onlyStaderContract(msg.sender, staderConfig.SD_COLLATERAL())) {
            if (repayAmountFinal > feeAccrued) {
                ISDCollateral(staderConfig.getSDCollateral()).reduceUtilizedSDPosition(
                    utilizer,
                    repayAmountFinal - feeAccrued
                );
            }
        }
        feePaid = Math.min(repayAmountFinal, feeAccrued);
        utilizerData[utilizer].principal = accountUtilizedPrev - repayAmountFinal;
        utilizerData[utilizer].utilizeIndex = utilizeIndex;
        totalUtilizedSD = totalUtilizedSD > repayAmountFinal ? totalUtilizedSD - repayAmountFinal : 0;
        emit Repaid(utilizer, repayAmountFinal);
    }

    /**
     * @notice Return the utilized balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return (calculated balance)
     */
    function _utilizerBalanceStoredInternal(address account) internal view returns (uint256) {
        /* Get utilizeBalance and utilizeIndex */
        UtilizerStruct storage utilizerSnapshot = utilizerData[account];

        /* If utilizedBalance = 0 then utilizeIndex is likely also 0.
         * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
         */
        if (utilizerSnapshot.principal == 0) {
            return 0;
        }

        /* Calculate new utilized balance using the utilize index:
         *  currentUtilizedBalance = utilizer.principal * utilizeIndex / utilizer.utilizeIndex
         */
        return (utilizerSnapshot.principal * utilizeIndex) / utilizerSnapshot.utilizeIndex;
    }

    /**
     * @notice Calculates the exchange rate between SD token and corresponding cToken
     * @dev This function does not accrue fee before calculating the exchange rate
     * @return calculated exchange rate scaled by 1e18
     */
    function _exchangeRateStored() internal view virtual returns (uint256) {
        if (cTokenTotalSupply == 0) {
            /*
             * if cToken supply is zero:
             *  exchangeRate = initialExchangeRate
             */
            return DECIMAL;
        } else {
            /*
             * Otherwise:
             *  exchangeRate = (poolAvailable SD + totalUtilizedSD - totalProtocolFee) / totalSupply
             */
            uint256 poolBalancePlusUtilizedSDMinusReserves = getPoolAvailableSDBalance() +
                totalUtilizedSD -
                accumulatedProtocolFee;
            uint256 exchangeRate = (poolBalancePlusUtilizedSDMinusReserves * DECIMAL) / cTokenTotalSupply;

            return exchangeRate;
        }
    }

    /// delete entry from delegatorWithdrawRequests mapping and in requestIdsByDelegatorAddress mapping
    function _deleteRequestId(uint256 _requestId) internal {
        delete (delegatorWithdrawRequests[_requestId]);
        uint256 userRequestCount = requestIdsByDelegatorAddress[msg.sender].length;
        uint256[] storage requestIds = requestIdsByDelegatorAddress[msg.sender];
        for (uint256 i; i < userRequestCount; ) {
            if (_requestId == requestIds[i]) {
                requestIds[i] = requestIds[userRequestCount - 1];
                requestIds.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
        revert CannotFindRequestId();
    }

    /// @notice Updates the risk configuration
    function _updateRiskConfig(
        uint256 liquidationThreshold,
        uint256 liquidationBonusPercent,
        uint256 liquidationFeePercent,
        uint256 ltv
    ) internal {
        if (liquidationThreshold > 100 || liquidationThreshold == 0) revert InvalidInput();
        if (liquidationBonusPercent > 100) revert InvalidInput();
        if (liquidationFeePercent > 100) revert InvalidInput();
        if (ltv > 100 || ltv == 0) revert InvalidInput();

        riskConfig = RiskConfig({
            liquidationThreshold: liquidationThreshold,
            liquidationBonusPercent: liquidationBonusPercent,
            liquidationFeePercent: liquidationFeePercent,
            ltv: ltv
        });
        emit RiskConfigUpdated(liquidationThreshold, liquidationBonusPercent, liquidationFeePercent, ltv);
    }
}
