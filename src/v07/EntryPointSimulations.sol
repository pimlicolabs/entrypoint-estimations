// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */

import "./EntryPoint.sol";
import "./IEntryPointSimulations.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {IEntryPoint as EP} from "account-abstraction/interfaces/IEntryPoint.sol";

struct SimulationArgs {
    PackedUserOperation op;
    address target;
    bytes targetCallData;
}

/*
 * This contract inherits the EntryPoint and extends it with the view-only methods that are executed by
 * the bundler in order to check UserOperation validity and estimate its gas consumption.
 * This contract should never be deployed on-chain and is only used as a parameter for the "eth_call" request.
 */
contract EntryPointSimulations is EntryPoint, IEntryPointSimulations {
    EntryPointSimulations immutable thisContract = this;
    AggregatorStakeInfo private NOT_AGGREGATED = AggregatorStakeInfo(address(0), StakeInfo(0, 0));
    SenderCreator private _senderCreator;

    // Thrown when the binary search fails due hitting the simulation gasLimit.
    error SimulationOutOfGas(uint256 optimalGas, uint256 minGas, uint256 maxGas);
    error innerCallResult(uint256 remainingGas);

    function initSenderCreator() internal virtual {
        //this is the address of the first contract created with CREATE by this address.
        address createdObj = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        _senderCreator = SenderCreator(createdObj);
    }

    function senderCreator() internal view virtual override returns (SenderCreator) {
        // return the same senderCreator as real EntryPoint.
        // this call is slightly (100) more expensive than EntryPoint's access to immutable member
        return _senderCreator;
    }

    /**
     * simulation contract should not be deployed, and specifically, accounts should not trust
     * it as entrypoint, since the simulation functions don't check the signatures
     */
    constructor() {}

    /// @inheritdoc IEntryPointSimulations
    function simulateValidation(PackedUserOperation calldata userOp) public returns (ValidationResult memory) {
        UserOpInfo memory outOpInfo;

        _simulationOnlyValidations(userOp);
        (
            uint256 validationData,
            uint256 paymasterValidationData, // uint256 paymasterVerificationGasLimit
        ) = _validatePrepayment(0, userOp, outOpInfo);

        _validateAccountAndPaymasterValidationData(0, validationData, paymasterValidationData, address(0));

        StakeInfo memory paymasterInfo = _getStakeInfo(outOpInfo.mUserOp.paymaster);
        StakeInfo memory senderInfo = _getStakeInfo(outOpInfo.mUserOp.sender);
        StakeInfo memory factoryInfo;
        {
            bytes calldata initCode = userOp.initCode;
            address factory = initCode.length >= 20 ? address(bytes20(initCode[0:20])) : address(0);
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
        if (uint160(aggregator) != SIG_VALIDATION_SUCCESS && uint160(aggregator) != SIG_VALIDATION_FAILED) {
            aggregatorInfo = AggregatorStakeInfo(aggregator, _getStakeInfo(aggregator));
        }
        return ValidationResult(returnInfo, senderInfo, factoryInfo, paymasterInfo, aggregatorInfo);
    }

    function simulateValidationBulk(PackedUserOperation[] calldata userOps)
        public
        returns (ValidationResult[] memory)
    {
        ValidationResult[] memory results = new ValidationResult[](userOps.length);

        for (uint256 i = 0; i < userOps.length; i++) {
            ValidationResult memory result = simulateValidation(userOps[i]);

            results[i] = result;
        }

        return results;
    }

    function simulateValidationLast(PackedUserOperation[] calldata userOps)
        external
        returns (ValidationResult memory)
    {
        ValidationResult[] memory results = simulateValidationBulk(userOps);

        return results[userOps.length - 1];
    }

    function simulateCallAndRevert(address target, bytes calldata data, uint256 gas) external {
        (bool success, bytes memory returnData) = target.call{gas: gas}(data);
        if (!success) {
            if (returnData.length == 0) revert();
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
    }

    // Helper function to perform the simulation and capture results from revert bytes.
    function simulateCall(address entryPoint, bytes calldata payload, uint256 gas)
        external
        returns (bool success, bytes memory result)
    {
        try EP(payable(entryPoint)).delegateAndRevert{gas: gas}(address(thisContract), payload) {}
        catch (bytes memory reason) {
            if (reason.length < 4) {
                // Calls that revert due to out of gas revert with empty bytes.
                return (false, new bytes(0));
            }

            bytes memory reasonData = new bytes(reason.length - 4);
            for (uint256 i = 4; i < reason.length; i++) {
                reasonData[i - 4] = reason[i];
            }
            (success, result) = abi.decode(reasonData, (bool, bytes));
        }
    }

    function processQueuedUserOps(SimulationArgs[] calldata queuedUserOps) internal {
        // Run all queued userOps to ensure that state is valid for the target userOp.
        for (uint256 i = 0; i < queuedUserOps.length; i++) {
            UserOpInfo memory queuedOpInfo;
            SimulationArgs calldata args = queuedUserOps[i];
            _simulationOnlyValidations(args.op);
            _validatePrepayment(0, args.op, queuedOpInfo);

            if (args.target == address(0)) {
                continue;
            }

            args.target.call(args.targetCallData);
        }
    }

    function binarySearchGasLimit(
        SimulationArgs[] calldata queuedUserOps,
        SimulationArgs calldata targetUserOp,
        address entryPoint,
        uint256 initialMinGas,
        uint256 toleranceDelta,
        uint256 gasAllowance,
        bytes memory payload
    ) internal returns (TargetCallResult memory) {
        processQueuedUserOps(queuedUserOps);
        // Extract out the target userOperation info.

        // Run our target userOperation.
        _simulationOnlyValidations(targetUserOp.op);

        uint256 minGas;
        bool targetSuccess;
        bytes memory targetResult;

        if (initialMinGas > 0) {
            targetSuccess = true;
            targetResult = hex"";
            minGas = initialMinGas;

            (targetSuccess, targetResult) = thisContract.simulateCall(entryPoint, payload, gasleft());

            // If the call reverts then don't binary search.
            if (!targetSuccess) {
                return TargetCallResult(0, targetSuccess, targetResult);
            }
        } else {
            // Find the minGas (reduces number of iterations + checks if the call reverts).
            uint256 remainingGas = gasleft();
            (targetSuccess, targetResult) = thisContract.simulateCall(entryPoint, payload, gasleft());
            minGas = remainingGas - gasleft();

            // If the call reverts then don't binary search.
            if (!targetSuccess) {
                return TargetCallResult(0, targetSuccess, targetResult);
            }
        }

        uint256 maxGas = minGas + gasAllowance;
        uint256 optimalGas = maxGas;

        while ((maxGas - minGas) >= toleranceDelta) {
            // Check that we can do one more run.
            if (gasleft() < minGas + 5_000) {
                revert SimulationOutOfGas(optimalGas, minGas, maxGas);
            }

            uint256 midGas = (minGas + maxGas) / 2;

            (bool success, bytes memory result) = thisContract.simulateCall(entryPoint, payload, midGas);

            if (success) {
                // If the call is successful, reduce the maxGas and store this as the candidate
                optimalGas = midGas;
                maxGas = midGas - 1;
                targetResult = result;
            } else {
                // If it fails, we need more gas, so increase the minGas
                minGas = midGas + 1;
            }
        }

        return TargetCallResult(optimalGas, targetSuccess, targetResult);
    }

    function binarySearchPaymasterVerificationGasLimit(
        SimulationArgs[] calldata queuedUserOps,
        SimulationArgs calldata targetUserOp,
        address entryPoint,
        uint256 initialMinGas,
        uint256 toleranceDelta,
        uint256 gasAllowance
    ) public returns (TargetCallResult memory) {
        UserOpInfo memory opInfo;
        bytes memory payload = abi.encodeWithSelector(this._paymasterValidation.selector, 0, targetUserOp.op, opInfo);

        return binarySearchGasLimit(
            queuedUserOps, targetUserOp, entryPoint, initialMinGas, toleranceDelta, gasAllowance, payload
        );
    }

    function binarySearchVerificationGasLimit(
        SimulationArgs[] calldata queuedUserOps,
        SimulationArgs calldata targetUserOp,
        address entryPoint,
        uint256 initialMinGas,
        uint256 toleranceDelta,
        uint256 gasAllowance
    ) public returns (TargetCallResult memory) {
        UserOpInfo memory opInfo;
        bytes memory payload = abi.encodeWithSelector(this._accountValidation.selector, 0, targetUserOp.op, opInfo);
        return binarySearchGasLimit(
            queuedUserOps, targetUserOp, entryPoint, initialMinGas, toleranceDelta, gasAllowance, payload
        );
    }

    /*
     * Helper function to estimate the call gas limit for a given userOperation.
     * The userOperation's callGasLimit is found by performing a onchain binary search.
     *
     * @param queuedUserOps - The userOperations that should be simulated before the targetUserOperation.
     * @param targetUserOp - The userOperation to simulate.
     * @param entryPoint - The address of the entryPoint contract.
     * @param toleranceDelta - The maximum difference between the estimated gas and the actual gas.
     * @param initialMinGas - The initial gas value to start the binary search with.
     * @param gasAllowance - The margin to add to the binary search to account for overhead.
     * @return optimalGas - The estimated gas limit for the call.
     */
    function binarySearchCallGasLimit(
        SimulationArgs[] calldata queuedUserOps,
        SimulationArgs calldata targetUserOp,
        address entryPoint,
        uint256 initialMinGas,
        uint256 toleranceDelta,
        uint256 gasAllowance
    ) public returns (TargetCallResult memory) {
        // Run all queued userOps to ensure that state is valid for the target userOp.
        for (uint256 i = 0; i < queuedUserOps.length; i++) {
            UserOpInfo memory queuedOpInfo;
            SimulationArgs calldata args = queuedUserOps[i];
            _simulationOnlyValidations(args.op);
            _validatePrepayment(0, args.op, queuedOpInfo);

            if (args.target == address(0)) {
                continue;
            }

            args.target.call(args.targetCallData);
        }

        // Extract out the target userOperation info.
        PackedUserOperation calldata op = targetUserOp.op;
        address target = targetUserOp.target;
        bytes memory targetCallData = targetUserOp.targetCallData;

        // Run our target userOperation.
        UserOpInfo memory opInfo;
        _simulationOnlyValidations(op);
        _validatePrepayment(0, op, opInfo);

        if (target == address(0)) {
            return TargetCallResult(0, false, new bytes(0));
        }

        uint256 minGas;
        bool targetSuccess;
        bytes memory targetResult;

        if (initialMinGas > 0) {
            targetSuccess = true;
            targetResult = hex"";
            minGas = initialMinGas;

            bytes memory payload =
                abi.encodeWithSelector(this.simulateCallAndRevert.selector, target, targetCallData, gasleft());
            (targetSuccess, targetResult) = thisContract.simulateCall(entryPoint, payload, gasleft());

            // If the call reverts then don't binary search.
            if (!targetSuccess) {
                return TargetCallResult(0, targetSuccess, targetResult);
            }
        } else {
            // Find the minGas (reduces number of iterations + checks if the call reverts).
            uint256 remainingGas = gasleft();
            bytes memory payload =
                abi.encodeWithSelector(this.simulateCallAndRevert.selector, target, targetCallData, gasleft());
            (targetSuccess, targetResult) = thisContract.simulateCall(entryPoint, payload, gasleft());
            minGas = remainingGas - gasleft();

            // If the call reverts then don't binary search.
            if (!targetSuccess) {
                return TargetCallResult(0, targetSuccess, targetResult);
            }
        }

        // Set bounds for binary search.
        uint256 maxGas = minGas + gasAllowance;
        uint256 optimalGas = maxGas;

        while ((maxGas - minGas) >= toleranceDelta) {
            // Check that we can do one more run.
            if (gasleft() < minGas + 5_000) {
                revert SimulationOutOfGas(optimalGas, minGas, maxGas);
            }

            uint256 midGas = (minGas + maxGas) / 2;

            bytes memory payload =
                abi.encodeWithSelector(this.simulateCallAndRevert.selector, target, targetCallData, midGas);
            (bool success, bytes memory result) = thisContract.simulateCall(entryPoint, payload, gasleft());

            if (success) {
                // If the call is successful, reduce the maxGas and store this as the candidate
                optimalGas = midGas;
                maxGas = midGas - 1;
                targetResult = result;
            } else {
                // If it fails, we need more gas, so increase the minGas
                minGas = midGas + 1;
            }
        }

        return TargetCallResult(optimalGas, targetSuccess, targetResult);
    }

    /// @inheritdoc IEntryPointSimulations
    function simulateHandleOp(PackedUserOperation calldata op) public nonReentrant returns (ExecutionResult memory) {
        UserOpInfo memory opInfo;
        _simulationOnlyValidations(op);
        (uint256 validationData, uint256 paymasterValidationData, uint256 paymasterVerificationGasLimit) =
            _validatePrepayment(0, op, opInfo);

        (uint256 paid, uint256 paymasterPostOpGasLimit) = _executeUserOp(op, opInfo);

        return ExecutionResult(
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

    function simulateHandleOpBulk(PackedUserOperation[] calldata ops) public returns (ExecutionResult[] memory) {
        ExecutionResult[] memory results = new ExecutionResult[](ops.length);

        for (uint256 i = 0; i < ops.length; i++) {
            ExecutionResult memory result = simulateHandleOp(ops[i]);

            results[i] = result;
        }

        return results;
    }

    function simulateHandleOpLast(PackedUserOperation[] calldata ops) external returns (ExecutionResult memory) {
        ExecutionResult[] memory results = new ExecutionResult[](ops.length);

        results = simulateHandleOpBulk(ops);

        return results[ops.length - 1];
    }

    function _simulationOnlyValidations(PackedUserOperation calldata userOp) internal {
        //initialize senderCreator(). we can't rely on constructor
        initSenderCreator();

        string memory revertReason =
            _validateSenderAndPaymaster(userOp.initCode, userOp.sender, userOp.paymasterAndData);
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
    function _validateSenderAndPaymaster(bytes calldata initCode, address sender, bytes calldata paymasterAndData)
        internal
        view
        returns (string memory)
    {
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
    function depositTo(address account) public payable override(IStakeManager, StakeManager) {
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
