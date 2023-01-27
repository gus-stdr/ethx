// SPDX-License-Identifier: MIT

pragma solidity ^0.8.16;

import './ETHX.sol';
import './interfaces/IStaderValidatorRegistry.sol';
import './interfaces/IStaderStakePoolManager.sol';
import './interfaces/ISocializingPoolContract.sol';
import './interfaces/IStaderOperatorRegistry.sol';
import './interfaces/IStaderOracle.sol';

import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';

/**
 *  @title Liquid Staking Pool Implementation
 *  Stader is a non-custodial smart contract-based staking platform
 *  that helps you conveniently discover and access staking solutions.
 *  We are building key staking middleware infra for multiple PoS networks
 * for retail crypto users, exchanges and custodians.
 */
contract StaderStakePoolsManager is IStaderStakePoolManager, TimelockControllerUpgradeable, PausableUpgradeable {
    using Math for uint256;

    ETHX public ethX;
    IStaderOracle public oracle;
    address public socializingPoolAddress;
    uint256 public constant DECIMALS = 10**18;
    uint256 public constant DEPOSIT_SIZE = 32 ether;
    uint256 public minDepositLimit;
    uint256 public maxDepositLimit;
    uint256 public totalELRewardsCollected;

    struct Pool {
        address poolAddress;
        uint256 poolWeight;
    }
    Pool[] public poolParameters;

    /// @notice Check for zero address
    /// @dev Modifier
    /// @param _address the address to check
    modifier checkZeroAddress(address _address) {
        require(_address != address(0), 'Address cannot be zero');
        _;
    }

    /**
     * @dev Stader initialized with following variables
     * @param _ethX ethX contract
     * @param _staderPermissionLessStakePoolAddress stader SSV Managed Pool, validator are assigned to operator through SSV
     * @param _staderPermissionedStakePoolAddress validator are assigned to operator, managed by stader
     * @param _staderPermissionLessStakePoolWeight weight of stader SSV pool, if it is 1 then validator gets operator via SSV
     * @param _staderPermissionedStakePoolWeight weight of stader managed pool
     * @param _minDelay initial minimum delay for operations
     * @param _proposers accounts to be granted proposer and canceller roles
     * @param _executors  accounts to be granted executor role
     * @param _timeLockOwner multi sig owner of the contract

     */
    function initialize(
        address _ethX,
        address _staderPermissionLessStakePoolAddress,
        address _staderPermissionedStakePoolAddress,
        uint256 _staderPermissionLessStakePoolWeight,
        uint256 _staderPermissionedStakePoolWeight,
        uint256 _minDelay,
        address[] memory _proposers,
        address[] memory _executors,
        address _timeLockOwner
    )
        external
        initializer
        checkZeroAddress(_ethX)
        checkZeroAddress(_staderPermissionLessStakePoolAddress)
        checkZeroAddress(_staderPermissionedStakePoolAddress)
    {
        require(
            _staderPermissionLessStakePoolWeight + _staderPermissionedStakePoolWeight == 100,
            'Invalid pool weights'
        );
        __TimelockController_init_unchained(_minDelay, _proposers, _executors, _timeLockOwner);
        __Pausable_init();
        Pool memory _staderPermissionLessStakePool = Pool(
            _staderPermissionLessStakePoolAddress,
            _staderPermissionLessStakePoolWeight
        );
        Pool memory _staderPermissionedStakePool = Pool(
            _staderPermissionedStakePoolAddress,
            _staderPermissionedStakePoolWeight
        );
        ethX = ETHX(_ethX);
        poolParameters.push(_staderPermissionLessStakePool);
        poolParameters.push(_staderPermissionedStakePool);
        _initialSetup();
    }

    /**
     * @notice Send funds to the pool
     * @dev Users are able to deposit their funds by transacting to the fallback function.
     * protection against accidental submissions by calling non-existent function
     */
    fallback() external payable {
        require(msg.value > minDepositLimit, 'Invalid Deposit amount');
        uint256 assets = msg.value;
        require(assets <= maxDeposit(_msgSender()), 'ERC4626: deposit more than max');
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), _msgSender(), assets, shares);
    }

    /**
     * @notice A payable function for execution layer rewards. Can be called only by executionLayerReward Contract
     * @dev We need a dedicated function because funds received by the default payable function
     * are treated as a user deposit
     */
    function receiveExecutionLayerRewards() external payable override {
        require(msg.sender == socializingPoolAddress);
        totalELRewardsCollected += msg.value;
        emit ExecutionLayerRewardsReceived(msg.value);
    }

    /**
     * @notice update the pool to register validators
     * @dev update the pool weights
     */
    function updatePoolWeights(uint256 _staderPermissionLessStakePoolWeight, uint256 _staderPermissionedStakePoolWeight)
        external
        onlyRole(TIMELOCK_ADMIN_ROLE)
    {
        require(_staderPermissionLessStakePoolWeight + _staderPermissionedStakePoolWeight == 100, 'Invalid weights');
        poolParameters[0].poolWeight = _staderPermissionLessStakePoolWeight;
        poolParameters[1].poolWeight = _staderPermissionedStakePoolWeight;
        emit UpdatedPoolWeights(poolParameters[0].poolWeight, poolParameters[1].poolWeight);
    }

    /**
     * @notice update the pool to register validators
     * @dev update the pool weights
     */
    function updateStaderPermissionLessStakePoolAddresses(address payable _staderPermissionLessStakePoolAddress)
        external
        checkZeroAddress(_staderPermissionLessStakePoolAddress)
        onlyRole(TIMELOCK_ADMIN_ROLE)
    {
        poolParameters[0].poolAddress = _staderPermissionLessStakePoolAddress;
        emit UpdatedPermissionLessPoolAddress(poolParameters[0].poolAddress);
    }

    /**
     * @notice update the pool to register validators
     * @dev update the pool weights
     */
    function updateStaderPermissionedPoolAddresses(address payable _staderPermissionedStakePoolAddress)
        external
        checkZeroAddress(_staderPermissionedStakePoolAddress)
        onlyRole(TIMELOCK_ADMIN_ROLE)
    {
        poolParameters[1].poolAddress = _staderPermissionedStakePoolAddress;
        emit UpdatedPermissionedPoolAddresses(poolParameters[1].poolAddress);
    }

    /**
     * @dev update the minimum stake amount
     * @param _minDepositLimit minimum deposit value
     */
    function updateMinDepositLimit(uint256 _minDepositLimit) external onlyRole(EXECUTOR_ROLE) {
        require(_minDepositLimit > 0, 'invalid minDeposit value');
        minDepositLimit = _minDepositLimit;
        emit UpdatedMinDepositLimit(minDepositLimit);
    }

    /**
     * @dev update the maximum stake amount
     * @param _maxDepositLimit maximum deposit value
     */
    function updateMaxDepositLimit(uint256 _maxDepositLimit) external onlyRole(EXECUTOR_ROLE) {
        require(_maxDepositLimit > minDepositLimit, 'invalid maxDeposit value');
        maxDepositLimit = _maxDepositLimit;
        emit UpdatedMaxDepositLimit(maxDepositLimit);
    }

    /**
     * @dev update ethX address
     * @param _ethX ethX contract
     */
    function updateEthXAddress(address _ethX) external checkZeroAddress(_ethX) onlyRole(TIMELOCK_ADMIN_ROLE) {
        ethX = ETHX(_ethX);
        emit UpdatedEthXAddress(address(ethX));
    }

    /**
     * @dev update ELRewardContract address
     * @param _socializingPoolAddress Socializing Pool Address
     */
    function updateSocializingPoolAddress(address _socializingPoolAddress)
        external
        checkZeroAddress(_socializingPoolAddress)
        onlyRole(EXECUTOR_ROLE)
    {
        socializingPoolAddress = _socializingPoolAddress;
        emit UpdatedSocializingPoolAddress(socializingPoolAddress);
    }

    /**
     * @dev update stader oracle address
     * @param _staderOracle stader oracle contract
     */
    function updateStaderOracle(address _staderOracle)
        external
        checkZeroAddress(_staderOracle)
        onlyRole(TIMELOCK_ADMIN_ROLE)
    {
        oracle = IStaderOracle(_staderOracle);
        emit UpdatedStaderOracle(address(oracle));
    }

    /**
     * @notice Returns the amount of ETHER equivalent 1 ETHX (with 18 decimals)
     */
    function getExchangeRate() public view returns (uint256) {
        uint256 totalETH = totalAssets();
        uint256 totalETHx = oracle.totalETHXSupply();

        if (totalETH == 0 || totalETHx == 0) {
            return 1 * DECIMALS;
        }
        return (totalETH * DECIMALS) / totalETHx;
    }

    /** @dev See {IERC4626-totalAssets}. */
    function totalAssets() public view returns (uint256) {
        return oracle.totalETHBalance();
    }

    /** @dev See {IERC4626-convertToShares}. */
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    /** @dev See {IERC4626-convertToAssets}. */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    /** @dev See {IERC4626-maxDeposit}. */
    function maxDeposit(address) public view returns (uint256) {
        return _isVaultHealthy() ? maxDepositLimit : 0;
    }

    /** @dev See {IERC4626-maxMint}. */
    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /** @dev See {IERC4626-maxWithdraw}. */
    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(ethX.balanceOf(owner), Math.Rounding.Down);
    }

    /** @dev See {IERC4626-maxRedeem}. */
    function maxRedeem(address owner) public view returns (uint256) {
        return ethX.balanceOf(owner);
    }

    /** @dev See {IERC4626-previewDeposit}. */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    /** @dev See {IERC4626-previewMint}. */
    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Up);
    }

    /** @dev See {IERC4626-previewWithdraw}. */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Up);
    }

    /** @dev See {IERC4626-previewRedeem}. */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    /** @dev See {IERC4626-deposit}. */
    function deposit(address receiver) public payable override whenNotPaused returns (uint256) {
        uint256 assets = msg.value;
        require(assets <= maxDeposit(receiver), 'ERC4626: deposit more than max');

        uint256 shares = previewDeposit(assets);
        require(shares <= maxMint(receiver), 'ERC4626: mint more than max');
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /** @dev See {IERC4626-mint}.
     *
     * As opposed to {deposit}, minting is allowed even if the vault is in a state where the price of a share is zero.
     * In this case, the shares will be minted without requiring any assets to be deposited.
     */
    function mint(uint256 shares, address receiver) public payable override whenNotPaused returns (uint256) {
        require(shares <= maxMint(receiver), 'ERC4626: mint more than max');

        uint256 assets = previewMint(shares);
        require(msg.value == assets, 'Invalid eth sent according to shares');
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /** @dev See {IERC4626-withdraw}. */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override whenNotPaused returns (uint256) {
        require(assets <= maxWithdraw(owner), 'ERC4626: withdraw more than max');

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /** @dev See {IERC4626-redeem}. */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override whenNotPaused returns (uint256) {
        require(shares <= maxRedeem(owner), 'ERC4626: redeem more than max');

        uint256 assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /**
     * @notice selecting a pool from SSSP and SMSP
     * @dev select a pool based on poolWeight
     */
    function selectPool() external onlyRole(EXECUTOR_ROLE) {
        uint256 balance = address(this).balance;
        //slither-disable-next-line low-level-calls arbitrary-send-eth
        (bool permissionLessPoolSuccess, ) = (poolParameters[0].poolAddress).call{
            value: (balance * poolParameters[0].poolWeight) / 100
        }('');
        require(permissionLessPoolSuccess, 'Stader PermissionLess Pool ETH transfer failed');

        //slither-disable-next-line low-level-calls
        //slither-disable-next-line arbitrary-send-eth
        (bool staderPoolSuccess, ) = payable(poolParameters[1].poolAddress).call{
            value: (balance * poolParameters[1].poolWeight) / 100
        }('');
        require(staderPoolSuccess, 'Stader Permissioned Pool ETH transfer failed');

        emit TransferredToPermissionLessPool(
            poolParameters[0].poolAddress,
            (balance * poolParameters[0].poolWeight) / 100
        );
        emit TransferredToStaderPermissionedPool(
            poolParameters[1].poolAddress,
            (balance * poolParameters[1].poolWeight) / 100
        );
    }

    function _initialSetup() internal {
        minDepositLimit = 1;
        maxDepositLimit = 32 ether;
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     *
     * Will revert if assets > 0, totalSupply > 0 and totalAssets = 0. That corresponds to a case where any asset
     * would represent an infinite amount of shares.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = oracle.totalETHXSupply();
        return
            (assets == 0 || supply == 0)
                ? _initialConvertToShares(assets, rounding)
                : assets.mulDiv(supply, totalAssets(), rounding);
    }

    /**
     * @dev Internal conversion function (from assets to shares) to apply when the vault is empty.
     *
     * NOTE: Make sure to keep this function consistent with {_initialConvertToAssets} when overriding it.
     */
    function _initialConvertToShares(
        uint256 assets,
        Math.Rounding /*rounding*/
    ) internal pure returns (uint256 shares) {
        return assets;
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = oracle.totalETHXSupply();
        return
            (supply == 0) ? _initialConvertToAssets(shares, rounding) : shares.mulDiv(totalAssets(), supply, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) to apply when the vault is empty.
     *
     * NOTE: Make sure to keep this function consistent with {_initialConvertToShares} when overriding it.
     */
    function _initialConvertToAssets(
        uint256 shares,
        Math.Rounding /*rounding*/
    ) internal pure returns (uint256) {
        return shares;
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        ethX.mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal {
        ethX.burnFrom(owner, shares);
        emit Withdrawn(caller, receiver, owner, assets, shares);
        //slither-disable-next-line arbitrary-send-eth
        payable(receiver).transfer(assets);
    }

    /**
     * @dev Checks if vault is "healthy" in the sense of having assets backing the circulating shares.
     */
    function _isVaultHealthy() private view returns (bool) {
        return totalAssets() > 0 || oracle.totalETHXSupply() == 0;
    }
}