// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import '../../library/UtilLib.sol';

import '../../library/ValidatorStatus.sol';

import '../../interfaces/IStaderConfig.sol';
import '../../interfaces/IVaultFactory.sol';
import '../../interfaces/IDepositContract.sol';
import '../../interfaces/DVT/SSV/ISSVPool.sol';
import '../../interfaces/IStaderInsuranceFund.sol';
import '../../interfaces/IStaderStakePoolManager.sol';
import '../../interfaces/DVT/SSV/ISSVNodeRegistry.sol';

import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';

contract SSVPool is ISSVPool, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using Math for uint256;

    IStaderConfig public staderConfig;
    // @inheritdoc IStaderPoolBase
    uint256 public override protocolFee;

    // @inheritdoc IStaderPoolBase
    uint256 public override operatorFee;

    uint256 public preDepositValidatorCount;

    uint256 public constant MAX_COMMISSION_LIMIT_BIPS = 1500;

    uint256 public constant DEPOSIT_NODE_BOND = 1.6 ether;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _admin, address _staderConfig) external initializer {
        UtilLib.checkNonZeroAddress(_admin);
        UtilLib.checkNonZeroAddress(_staderConfig);
        __AccessControl_init_unchained();
        __ReentrancyGuard_init();
        protocolFee = 500;
        operatorFee = 500;
        staderConfig = IStaderConfig(_staderConfig);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function receiveInsuranceFund() external payable {
        UtilLib.onlyStaderContract(msg.sender, staderConfig, staderConfig.STADER_INSURANCE_FUND());
        emit ReceivedInsuranceFund(msg.value);
    }

    // transfer the 32ETH for defective keys (front run, invalid signature) to stader stake pool manager (SSPM)
    function transferETHOfDefectiveKeysToSSPM(uint256 _defectiveKeyCount) external nonReentrant {
        UtilLib.onlyStaderContract(msg.sender, staderConfig, staderConfig.SSV_NODE_REGISTRY());
        //decrease the preDeposit validator count
        _decreasePreDepositValidatorCount(_defectiveKeyCount);
        //get 1ETH from insurance fund
        IStaderInsuranceFund(staderConfig.getStaderInsuranceFund()).reimburseUserFund(
            _defectiveKeyCount * staderConfig.getPreDepositSize()
        );
        // send back 30.4 ETH (32 - collateral) for front run and invalid signature validators back to pool manager
        // These counts are correct because any double reporting of frontrun/invalid statuses results in an error.
        uint256 amountToSendToPoolManager = _defectiveKeyCount *
            (staderConfig.getStakedEthPerNode() - DEPOSIT_NODE_BOND);
        //slither-disable-next-line arbitrary-send-eth
        IStaderStakePoolManager(staderConfig.getStakePoolManager()).receiveExcessEthFromPool{
            value: amountToSendToPoolManager
        }(INodeRegistry((staderConfig).getSSVNodeRegistry()).POOL_ID());
        emit TransferredETHToSSPMForDefectiveKeys(amountToSendToPoolManager);
    }

    /**
     * @notice receives eth from pool manager to deposit for validators on beacon chain
     * @dev deposit PRE_DEPOSIT_SIZE of ETH for validators while adhering to pool capacity.
     */
    function stakeUserETHToBeaconChain() external payable override nonReentrant {
        UtilLib.onlyStaderContract(msg.sender, staderConfig, staderConfig.STAKE_POOL_MANAGER());
        uint256 requiredValidators = msg.value / (staderConfig.getStakedEthPerNode() - DEPOSIT_NODE_BOND);
        address nodeRegistryAddress = staderConfig.getSSVNodeRegistry();

        address vaultFactoryAddress = staderConfig.getVaultFactory();
        address ethDepositContract = staderConfig.getETHDepositContract();
        uint256 depositQueueStartIndex = ISSVNodeRegistry(nodeRegistryAddress).nextQueuedValidatorIndex();
        for (uint256 i = depositQueueStartIndex; i < requiredValidators + depositQueueStartIndex; ) {
            _preDepositOnBeaconChain(nodeRegistryAddress, vaultFactoryAddress, ethDepositContract, i);
            unchecked {
                ++i;
            }
        }
        ISSVNodeRegistry(nodeRegistryAddress).updateNextQueuedValidatorIndex(
            depositQueueStartIndex + requiredValidators
        );
        _increasePreDepositValidatorCount(requiredValidators);
        ISSVNodeRegistry(nodeRegistryAddress).increaseTotalActiveValidatorCount(requiredValidators);
    }

    // deposit `FULL_DEPOSIT_SIZE` for the verified preDeposited Validator
    function fullDepositOnBeaconChain(bytes[] calldata _pubkey) external nonReentrant {
        UtilLib.onlyStaderContract(msg.sender, staderConfig, staderConfig.SSV_NODE_REGISTRY());
        address nodeRegistryAddress = msg.sender;
        address vaultFactory = staderConfig.getVaultFactory();
        address ethDepositContract = staderConfig.getETHDepositContract();
        uint256 pubkeyCount = _pubkey.length;
        //decrease the preDeposit validator count
        _decreasePreDepositValidatorCount(pubkeyCount);
        for (uint256 i; i < pubkeyCount; ) {
            ISSVNodeRegistry(nodeRegistryAddress).onlySSVRegisteredAndPreDepositValidator(_pubkey[i]);
            uint256 validatorId = INodeRegistry(nodeRegistryAddress).validatorIdByPubkey(_pubkey[i]);
            (, , , bytes memory depositSignature, address withdrawVaultAddress, , , ) = INodeRegistry(
                nodeRegistryAddress
            ).validatorRegistry(validatorId);
            bytes memory withdrawCredential = IVaultFactory(vaultFactory).getValidatorWithdrawCredential(
                withdrawVaultAddress
            );
            uint256 fullDepositSize = staderConfig.getFullDepositSize();
            bytes32 depositDataRoot = this.computeDepositDataRoot(
                _pubkey[i],
                depositSignature,
                withdrawCredential,
                fullDepositSize
            );

            //slither-disable-next-line arbitrary-send-eth
            IDepositContract(ethDepositContract).deposit{value: fullDepositSize}(
                _pubkey[i],
                withdrawCredential,
                depositSignature,
                depositDataRoot
            );
            // ISSVNodeRegistry(nodeRegistryAddress).updateDepositStatusAndBlock(validatorId);
            emit ValidatorDepositedOnBeaconChain(validatorId, _pubkey[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice transfer the excess ETH sent by some EAO or non stader contract back to SSPM
     * @dev preDepositValidatorCount has to be 0 for determining excess ETH value
     */
    function transferExcessETHToSSPM() external nonReentrant {
        if (preDepositValidatorCount != 0 || address(this).balance == 0) {
            revert CouldNotDetermineExcessETH();
        }
        IStaderStakePoolManager(staderConfig.getStakePoolManager()).receiveExcessEthFromPool{
            value: address(this).balance
        }(INodeRegistry((staderConfig).getSSVNodeRegistry()).POOL_ID());
    }

    function getNodeRegistry() external view override returns (address) {
        return staderConfig.getSSVNodeRegistry();
    }

    // @inheritdoc IStaderPoolBase
    function getSocializingPoolAddress() external view returns (address) {
        return staderConfig.getSSVSocializingPool();
    }

    // @inheritdoc IStaderPoolBase
    function setCommissionFees(uint256 _protocolFee, uint256 _operatorFee) external {
        UtilLib.onlyManagerRole(msg.sender, staderConfig);
        if (_protocolFee + _operatorFee > MAX_COMMISSION_LIMIT_BIPS) {
            revert InvalidCommission();
        }
        protocolFee = _protocolFee;
        operatorFee = _operatorFee;

        emit UpdatedCommissionFees(_protocolFee, _operatorFee);
    }

    //update the address of staderConfig
    function updateStaderConfig(address _staderConfig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        UtilLib.checkNonZeroAddress(_staderConfig);
        staderConfig = IStaderConfig(_staderConfig);
        emit UpdatedStaderConfig(_staderConfig);
    }

    // @notice calculate the deposit data root based on pubkey, signature, withdrawCredential and amount
    // formula based on ethereum deposit contract
    function computeDepositDataRoot(
        bytes calldata _pubkey,
        bytes calldata _signature,
        bytes calldata _withdrawCredential,
        uint256 _depositAmount
    ) external pure returns (bytes32) {
        bytes memory amount = to_little_endian_64(_depositAmount);
        bytes32 pubkey_root = sha256(abi.encodePacked(_pubkey, bytes16(0)));
        bytes32 signature_root = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(_signature[:64])),
                sha256(abi.encodePacked(_signature[64:], bytes32(0)))
            )
        );
        return
            sha256(
                abi.encodePacked(
                    sha256(abi.encodePacked(pubkey_root, _withdrawCredential)),
                    sha256(abi.encodePacked(amount, bytes24(0), signature_root))
                )
            );
    }

    function _increasePreDepositValidatorCount(uint256 _count) internal {
        preDepositValidatorCount += _count;
    }

    function _decreasePreDepositValidatorCount(uint256 _count) internal {
        preDepositValidatorCount -= _count;
    }

    // deposit `PRE_DEPOSIT_SIZE` for validator
    function _preDepositOnBeaconChain(
        address _nodeRegistryAddress,
        address _vaultFactory,
        address _ethDepositContract,
        uint256 _validatorId
    ) internal {
        (, bytes memory pubkey, bytes memory preDepositSignature, , address withdrawVaultAddress, , , ) = INodeRegistry(
            _nodeRegistryAddress
        ).validatorRegistry(_validatorId);

        bytes memory withdrawCredential = IVaultFactory(_vaultFactory).getValidatorWithdrawCredential(
            withdrawVaultAddress
        );
        uint256 preDepositSize = staderConfig.getPreDepositSize();
        bytes32 depositDataRoot = this.computeDepositDataRoot(
            pubkey,
            preDepositSignature,
            withdrawCredential,
            preDepositSize
        );

        //slither-disable-next-line arbitrary-send-eth
        IDepositContract(_ethDepositContract).deposit{value: preDepositSize}(
            pubkey,
            withdrawCredential,
            preDepositSignature,
            depositDataRoot
        );
        ISSVNodeRegistry(_nodeRegistryAddress).markValidatorStatusAsPreDeposit(pubkey);
        emit ValidatorPreDepositedOnBeaconChain(pubkey);
    }

    //ethereum deposit contract function to get amount into little_endian_64
    function to_little_endian_64(uint256 _depositAmount) internal pure returns (bytes memory ret) {
        uint64 value = uint64(_depositAmount / 1 gwei);

        ret = new bytes(8);
        bytes8 bytesValue = bytes8(value);
        // Byteswapping during copying to bytes.
        ret[0] = bytesValue[7];
        ret[1] = bytesValue[6];
        ret[2] = bytesValue[5];
        ret[3] = bytesValue[4];
        ret[4] = bytesValue[3];
        ret[5] = bytesValue[2];
        ret[6] = bytesValue[1];
        ret[7] = bytesValue[0];
    }
}
