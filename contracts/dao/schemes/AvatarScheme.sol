// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "./Scheme.sol";

/**
 * @title AvatarScheme.
 * @dev  A scheme for proposing and executing calls to any contract from the DAO avatar
 * It has a value call controller address, in case the controller address is set the scheme will be doing
 * generic calls to the dao controller. If the controller address is not set it will be executing raw calls from the

 * scheme itself.
 * The scheme can only execute calls allowed to in the permission registry, if the controller address is set
 * the permissions will be checked using the avatar address as sender, if not the scheme address will be used as
 * sender.
 */
contract AvatarScheme is Scheme {
    using Address for address;

    /// @notice Emitted when setMaxSecondsForExecution NOT called from the avatar
    error AvatarScheme__SetMaxSecondsForExecutionNotCalledFromAvatar();

    /// @notice Emitted when trying to set maxSecondsForExecution to a value lower than 86400
    error AvatarScheme__MaxSecondsForExecutionTooLow();

    /// @notice Emitted when the proposal is already being executed
    error AvatarScheme__ProposalExecutionAlreadyRunning();

    /// @notice Emitted when the proposal wasn't submitted
    error AvatarScheme__ProposalMustBeSubmitted();

    /// @notice Emitted when the call to setETHPermissionUsed fails
    error AvatarScheme__SetEthPermissionUsedFailed();

    /// @notice Emitted when the avatarCall failed. Returns the revert error
    error AvatarScheme__AvatarCallFailed(string reason);

    /// @notice Emitted when exceeded the maximum rep supply % change
    error AvatarScheme__MaxRepPercentageChangePassed();

    /// @notice Emitted when ERC20 limits passed
    error AvatarScheme__ERC20LimitsPassed();

    /**
     * @dev Set the max amount of seconds that a proposal has to be executed
     * only callable from the avatar address
     * @param _maxSecondsForExecution New max proposal time in seconds to be used
     */
    function setMaxSecondsForExecution(uint256 _maxSecondsForExecution) external override {
        if (msg.sender != address(avatar)) {
            revert AvatarScheme__SetMaxSecondsForExecutionNotCalledFromAvatar();
        }

        if (_maxSecondsForExecution < 86400) {
            revert AvatarScheme__MaxSecondsForExecutionTooLow();
        }

        maxSecondsForExecution = _maxSecondsForExecution;
    }

    /**
     * @dev execution of proposals, can only be called by the voting machine in which the vote is held.
     * @param _proposalId the ID of the voting in the voting machine
     * @param _winningOption The winning option in the voting machine
     * @return bool success
     */
    function executeProposal(bytes32 _proposalId, uint256 _winningOption)
        external
        override
        onlyVotingMachine
        returns (bool)
    {
        // We use isExecutingProposal variable to avoid re-entrancy in proposal execution
        if (executingProposal) {
            revert AvatarScheme__ProposalExecutionAlreadyRunning();
        }
        executingProposal = true;

        Proposal storage proposal = proposals[_proposalId];
        if (proposal.state != ProposalState.Submitted) {
            revert AvatarScheme__ProposalMustBeSubmitted();
        }

        if ((proposal.submittedTime + maxSecondsForExecution) < block.timestamp) {
            // If the amount of time passed since submission plus max proposal time is lower than block timestamp
            // the proposal timeout execution is reached and proposal cant be executed from now on

            proposal.state = ProposalState.ExecutionTimeout;
            emit ProposalStateChange(_proposalId, uint256(ProposalState.ExecutionTimeout));
        } else if (_winningOption == 2) {
            proposal.state = ProposalState.Rejected;
            emit ProposalStateChange(_proposalId, uint256(ProposalState.Rejected));
        } else {
            uint256 oldRepSupply = getNativeReputationTotalSupply();
            proposal.state = ProposalState.ExecutionSucceeded;
            emit ProposalStateChange(_proposalId, uint256(ProposalState.ExecutionSucceeded));

            controller.avatarCall(
                address(permissionRegistry),
                abi.encodeWithSignature("setERC20Balances()"),
                avatar,
                0
            );

            uint256 callIndex = 0;

            for (callIndex; callIndex < proposal.to.length; callIndex++) {
                bytes memory _data = proposal.callData[callIndex];
                bytes4 callDataFuncSignature;
                assembly {
                    callDataFuncSignature := mload(add(_data, 32))
                }

                bool callsSucessResult = false;
                bytes memory returnData;

                // The only three calls that can be done directly to the controller is mintReputation, burnReputation and avatarCall
                if (
                    proposal.to[callIndex] == address(controller) &&
                    (callDataFuncSignature == bytes4(keccak256("mintReputation(uint256,address)")) ||
                        callDataFuncSignature == bytes4(keccak256("burnReputation(uint256,address)")))
                ) {
                    (callsSucessResult, ) = address(controller).call(proposal.callData[callIndex]);
                } else {
                    // The permission registry keeps track of all value transferred and checks call permission
                    (callsSucessResult, returnData) = controller.avatarCall(
                        address(permissionRegistry),
                        abi.encodeWithSignature(
                            "setETHPermissionUsed(address,address,bytes4,uint256)",
                            avatar,
                            proposal.to[callIndex],
                            callDataFuncSignature,
                            proposal.value[callIndex]
                        ),
                        avatar,
                        0
                    );
                    if (!callsSucessResult) {
                        revert AvatarScheme__SetEthPermissionUsedFailed();
                    }
                    (callsSucessResult, returnData) = controller.avatarCall(
                        proposal.to[callIndex],
                        proposal.callData[callIndex],
                        avatar,
                        proposal.value[callIndex]
                    );
                }
                if (!callsSucessResult) {
                    revert AvatarScheme__AvatarCallFailed({reason: string(returnData)});
                }
            }

            // Cant mint or burn more REP than the allowed percentaged set in the wallet scheme initialization

            if (
                ((oldRepSupply * (uint256(100) + maxRepPercentageChange)) / 100 < getNativeReputationTotalSupply()) ||
                ((oldRepSupply * (uint256(100) - maxRepPercentageChange)) / 100 > getNativeReputationTotalSupply())
            ) {
                revert AvatarScheme__MaxRepPercentageChangePassed();
            }

            if (!permissionRegistry.checkERC20Limits(address(avatar))) {
                revert AvatarScheme__ERC20LimitsPassed();
            }
        }
        controller.endProposal(_proposalId);
        executingProposal = false;
        return true;
    }

    /**
     * @dev Get the scheme type
     */
    function getSchemeType() external view override returns (string memory) {
        return "AvatarScheme_v1";
    }
}
