// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./Scheme.sol";

/**
 * @title AvatarScheme.
 * @dev  A scheme for proposing and executing calls to any contract from the DAO avatar
 * It has a value call controller address, in case of the controller address ot be set the scheme will be doing
 * generic calls to the dao controller. If the controller address is not set it will e executing raw calls form the
 * scheme itself.
 * The scheme can only execute calls allowed to in the permission registry, if the controller address is set
 * the permissions will be checked using the avatar address as sender, if not the scheme address will be used as
 * sender.
 */
contract AvatarScheme is Scheme {
    using SafeMath for uint256;
    using Address for address;

    /**
     * @dev execution of proposals, can only be called by the voting machine in which the vote is held.
        REQUIRE FROM "../daostack/votingMachines/ProposalExecuteInterface.sol" DONT REMOVE
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
        require(!executingProposal, "AvatarScheme: proposal execution already running");
        executingProposal = true;

        Proposal storage proposal = proposals[_proposalId];
        require(proposal.state == ProposalState.Submitted, "AvatarScheme: must be a submitted proposal");

        require(
            controller.getSchemeCanMakeAvatarCalls(address(this)),
            "AvatarScheme: scheme have to make avatar calls"
        );

        if (_winningOption == 0) {
            proposal.state = ProposalState.Rejected;
            emit ProposalStateChange(_proposalId, uint256(ProposalState.Rejected));
        } else if (proposal.submittedTime.add(maxSecondsForExecution) < block.timestamp) {
            // If the amount of time passed since submission plus max proposal time is lower than block timestamp
            // the proposal timeout execution is reached and proposal cant be executed from now on

            proposal.state = ProposalState.ExecutionTimeout;
            emit ProposalStateChange(_proposalId, uint256(ProposalState.ExecutionTimeout));
        } else {
            uint256 oldRepSupply = getNativeReputationTotalSupply();

            // proposal.to.length.div( proposal.totalOptions ) == Calls per option
            // We dont assign it as variable to avoid hitting stack too deep error
            uint256 callIndex = proposal.to.length.div(proposal.totalOptions).mul(_winningOption.sub(1));
            uint256 lastCallIndex = callIndex.add(proposal.to.length.div(proposal.totalOptions));

            controller.avatarCall(
                address(permissionRegistry),
                abi.encodeWithSignature("setERC20Balances()"),
                avatar,
                0
            );

            for (callIndex; callIndex < lastCallIndex; callIndex++) {
                bytes memory _data = proposal.callData[callIndex];
                bytes4 callDataFuncSignature;
                assembly {
                    callDataFuncSignature := mload(add(_data, 32))
                }

                bool callsSucessResult = false;
                // The permission registry keeps track of all value transferred and checks call permission
                (callsSucessResult, ) = controller.avatarCall(
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
                require(callsSucessResult, "AvatarScheme: setETHPermissionUsed failed");

                (callsSucessResult, ) = controller.avatarCall(
                    proposal.to[callIndex],
                    proposal.callData[callIndex],
                    avatar,
                    proposal.value[callIndex]
                );
                require(callsSucessResult, "AvatarScheme: Proposal call failed");

                proposal.state = ProposalState.ExecutionSucceeded;
            }

            // Cant mint or burn more REP than the allowed percentaged set in the wallet scheme initialization
            require(
                (oldRepSupply.mul(uint256(100).add(maxRepPercentageChange)).div(100) >=
                    getNativeReputationTotalSupply()) &&
                    (oldRepSupply.mul(uint256(100).sub(maxRepPercentageChange)).div(100) <=
                        getNativeReputationTotalSupply()),
                "AvatarScheme: maxRepPercentageChange passed"
            );

            require(permissionRegistry.checkERC20Limits(address(avatar)), "AvatarScheme: ERC20 limits passed");

            emit ProposalStateChange(_proposalId, uint256(ProposalState.ExecutionSucceeded));
        }
        executingProposal = false;
        return true;
    }
}
