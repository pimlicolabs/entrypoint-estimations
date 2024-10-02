// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */

import "./EntryPoint.sol";
import "./IEntryPointSimulations.sol";

/*
 * This contract inherits the EntryPoint and extends it with the view-only methods that are executed by
 * the bundler in order to check UserOperation validity and estimate its gas consumption.
 * This contract should never be deployed on-chain and is only used as a parameter for the "eth_call" request.
 */
contract EntryPointSimulations is EntryPoint, IEntryPointSimulations {
    // solhint-disable-next-line var-name-mixedcase
    AggregatorStakeInfo private NOT_AGGREGATED =
        AggregatorStakeInfo(address(0), StakeInfo(0, 0));

    SenderCreator private _senderCreator;

    function initSenderCreator() internal virtual {
        //this is the address of the first contract created with CREATE by this address.
        address createdObj = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"d694", address(this), hex"01")
                    )
                )
            )
        );
        _senderCreator = SenderCreator(createdObj);
    }

    function senderCreator()
        internal
        view
        virtual
        override
        returns (SenderCreator)
    {
        // return the same senderCreator as real EntryPoint.
        // this call is slightly (100) more expensive than EntryPoint's access to immutable member
        return _senderCreator;
    }

    /**
     * simulation contract should not be deployed, and specifically, accounts should not trust
     * it as entrypoint, since the simulation functions don't check the signatures
     */
    constructor() {
        // require(block.number < 100, "should not be deployed");
    }

    /// @inheritdoc IEntryPointSimulations
    function simulateValidation(
        PackedUserOperation calldata userOp
    ) public returns (ValidationResult memory) {
        UserOpInfo memory outOpInfo;

        _simulationOnlyValidations(userOp);
        (
            uint256 validationData,
            uint256 paymasterValidationData,

        ) = // uint256 paymasterVerificationGasLimit
            _validatePrepayment(0, userOp, outOpInfo);

        _validateAccountAndPaymasterValidationData(
            0,
            validationData,
            paymasterValidationData,
            address(0)
        );

        StakeInfo memory paymasterInfo = _getStakeInfo(
            outOpInfo.mUserOp.paymaster
        );
        StakeInfo memory senderInfo = _getStakeInfo(outOpInfo.mUserOp.sender);
        StakeInfo memory factoryInfo;
        {
            bytes calldata initCode = userOp.initCode;
            address factory = initCode.length >= 20
                ? address(bytes20(initCode[0:20]))
                : address(0);
            factoryInfo = _getStakeInfo(factory);
        }

        address aggregator = address(uint160(validationData));
        ReturnInfo memory returnInfo = ReturnInfo(
            outOpInfo.preOpGas,
            outOpInfo.prefund,
            validationData,
            paymasterValidationData,
            getMemoryBytesFromOffset(outOpInfo.contextOffset)
        );

        AggregatorStakeInfo memory aggregatorInfo = NOT_AGGREGATED;
        if (
            uint160(aggregator) != SIG_VALIDATION_SUCCESS &&
            uint160(aggregator) != SIG_VALIDATION_FAILED
        ) {
            aggregatorInfo = AggregatorStakeInfo(
                aggregator,
                _getStakeInfo(aggregator)
            );
        }
        return
            ValidationResult(
                returnInfo,
                senderInfo,
                factoryInfo,
                paymasterInfo,
                aggregatorInfo
            );
    }

    function simulateValidationBulk(
        PackedUserOperation[] calldata userOps
    ) public returns (ValidationResult[] memory) {
        ValidationResult[] memory results = new ValidationResult[](
            userOps.length
        );

        for (uint256 i = 0; i < userOps.length; i++) {
            ValidationResult memory result = simulateValidation(userOps[i]);

            results[i] = result;
        }

        return results;
    }

    function simulateValidationLast(
        PackedUserOperation[] calldata userOps
    ) external returns (ValidationResult memory) {
        ValidationResult[] memory results = simulateValidationBulk(userOps);

        return results[userOps.length - 1];
    }

    function simulateCallData(
        PackedUserOperation calldata op,
        address target,
        bytes calldata targetCallData
    ) public returns (TargetCallResult memory) {
        UserOpInfo memory opInfo;
        _simulationOnlyValidations(op);
        _validatePrepayment(0, op, opInfo);

        bool targetSuccess;
        bytes memory targetResult;
        uint256 minGas = 21000;
        uint256 maxGas = uint128(uint256(op.accountGasLimits));
        uint256 optimalGas = maxGas;
        if (target != address(0)) {
            while (minGas <= maxGas) {
                uint256 midGas = (minGas + maxGas) / 2;

                try this.tryCall{gas: midGas}(target, targetCallData) {
                    // If the call is successful, reduce the maxGas and store this as the candidate
                    optimalGas = midGas;
                    maxGas = midGas - 1;
                } catch {
                    // If it fails, we need more gas, so increase the minGas
                    minGas = midGas + 1;
                }
            }
        }

        return TargetCallResult(optimalGas, targetSuccess, targetResult);
    }

    error innerCallResult(uint256 remainingGas);

    function tryCall(address target, bytes memory targetCallData) external {
        // Use a low-level call to the target contract with the specified gas
        (bool success, ) = target.call(targetCallData);

        // Revert if the call fails
        require(success, "Target call failed");

        // Otherwise, if successful, the function will exit normally
    }

    function simulateCallDataBulk(
        PackedUserOperation[] calldata ops,
        address[] calldata targets,
        bytes[] calldata targetCallData
    ) public returns (TargetCallResult[] memory) {
        TargetCallResult[] memory results = new TargetCallResult[](ops.length);

        for (uint256 i = 0; i < ops.length; i++) {
            TargetCallResult memory result = simulateCallData(
                ops[i],
                targets[i],
                targetCallData[i]
            );

            results[i] = result;
        }

        return results;
    }

    function simulateCallDataLast(
        PackedUserOperation[] calldata ops,
        address[] calldata targets,
        bytes[] calldata targetCallData
    ) external returns (TargetCallResult memory) {
        TargetCallResult[] memory results = simulateCallDataBulk(
            ops,
            targets,
            targetCallData
        );

        return results[ops.length - 1];
    }

    /// @inheritdoc IEntryPointSimulations
    function simulateHandleOp(
        PackedUserOperation calldata op
    ) public nonReentrant returns (ExecutionResult memory) {
        UserOpInfo memory opInfo;
        _simulationOnlyValidations(op);
        (
            uint256 validationData,
            uint256 paymasterValidationData,
            uint256 paymasterVerificationGasLimit
        ) = _validatePrepayment(0, op, opInfo);

        (uint256 paid, uint256 paymasterPostOpGasLimit) = _executeUserOp(
            op,
            opInfo
        );

        return
            ExecutionResult(
                opInfo.preOpGas,
                paid,
                validationData,
                paymasterValidationData,
                paymasterVerificationGasLimit,
                paymasterPostOpGasLimit,
                false,
                "0x"
            );
    }

    function simulateHandleOpBulk(
        PackedUserOperation[] calldata ops
    ) public returns (ExecutionResult[] memory) {
        ExecutionResult[] memory results = new ExecutionResult[](ops.length);

        for (uint256 i = 0; i < ops.length; i++) {
            ExecutionResult memory result = simulateHandleOp(ops[i]);

            results[i] = result;
        }

        return results;
    }

    function simulateHandleOpLast(
        PackedUserOperation[] calldata ops
    ) external returns (ExecutionResult memory) {
        ExecutionResult[] memory results = new ExecutionResult[](ops.length);

        results = simulateHandleOpBulk(ops);

        return results[ops.length - 1];
    }

    function _simulationOnlyValidations(
        PackedUserOperation calldata userOp
    ) internal {
        //initialize senderCreator(). we can't rely on constructor
        initSenderCreator();

        string memory revertReason = _validateSenderAndPaymaster(
            userOp.initCode,
            userOp.sender,
            userOp.paymasterAndData
        );
        // solhint-disable-next-line no-empty-blocks
        if (bytes(revertReason).length != 0) {
            revert FailedOp(0, revertReason);
        }
    }

    /**
     * Called only during simulation.
     * This function always reverts to prevent warm/cold storage differentiation in simulation vs execution.
     * @param initCode         - The smart account constructor code.
     * @param sender           - The sender address.
     * @param paymasterAndData - The paymaster address (followed by other params, ignored by this method)
     */
    function _validateSenderAndPaymaster(
        bytes calldata initCode,
        address sender,
        bytes calldata paymasterAndData
    ) internal view returns (string memory) {
        if (initCode.length == 0 && sender.code.length == 0) {
            // it would revert anyway. but give a meaningful message
            return ("AA20 account not deployed");
        }
        if (paymasterAndData.length >= 20) {
            address paymaster = address(bytes20(paymasterAndData[0:20]));
            if (paymaster.code.length == 0) {
                // It would revert anyway. but give a meaningful message.
                return ("AA30 paymaster not deployed");
            }
        }
        // always revert
        return ("");
    }

    //make sure depositTo cost is more than normal EntryPoint's cost,
    // to mitigate DoS vector on the bundler
    // empiric test showed that without this wrapper, simulation depositTo costs less..
    function depositTo(
        address account
    ) public payable override(IStakeManager, StakeManager) {
        unchecked {
            // silly code, to waste some gas to make sure depositTo is always little more
            // expensive than on-chain call
            uint256 x = 1;
            while (x < 5) {
                x++;
            }
            StakeManager.depositTo(account);
        }
    }
}
