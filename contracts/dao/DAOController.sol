// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "./DAOAvatar.sol";
import "./DAOReputation.sol";

/**
 * @title DAO Controller
 * @dev A controller controls and connect the organizations schemes, reputation and avatar.
 * The schemes execute proposals through the controller to the avatar.
 * Each scheme has it own parameters and operation permissions.
 */
contract DAOController is Initializable {
    using SafeMathUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.Bytes32Set;

    EnumerableSetUpgradeable.Bytes32Set private activeProposals;
    EnumerableSetUpgradeable.Bytes32Set private inactiveProposals;
    mapping(bytes32 => address) public schemeOfProposal;

    struct ProposalAndScheme {
        bytes32 proposalId;
        address scheme;
    }

    DAOReputation public reputationToken;

    struct Scheme {
        bytes32 paramsHash; // a hash voting parameters of the scheme
        bool isRegistered;
        bool canManageSchemes;
        bool canMakeAvatarCalls;
    }

    mapping(address => Scheme) public schemes;
    uint256 public schemesWithManageSchemesPermission;

    event RegisterScheme(address indexed _sender, address indexed _scheme);
    event UnregisterScheme(address indexed _sender, address indexed _scheme);

    function initialize(
        address _scheme,
        address _reputationToken,
        bytes32 _paramsHash
    ) public initializer {
        schemes[_scheme] = Scheme({
            paramsHash: _paramsHash,
            isRegistered: true,
            canManageSchemes: true,
            canMakeAvatarCalls: true
        });
        schemesWithManageSchemesPermission = 1;
        reputationToken = DAOReputation(_reputationToken);
    }

    modifier onlyRegisteredScheme() {
        require(schemes[msg.sender].isRegistered, "DAOController: Sender is not a registered scheme");
        _;
    }

    modifier onlyRegisteringSchemes() {
        require(schemes[msg.sender].canManageSchemes, "DAOController: Sender cannot manage schemes");
        _;
    }

    modifier onlyAvatarCallScheme() {
        require(schemes[msg.sender].canMakeAvatarCalls, "DAOController: Sender cannot perform avatar calls");
        _;
    }

    /**
     * @dev register a scheme
     * @param _scheme the address of the scheme
     * @param _paramsHash a hashed configuration of the usage of the scheme
     * @param _canManageSchemes whether the scheme is able to manage schemes
     * @param _canMakeAvatarCalls whether the scheme is able to make avatar calls
     * @return bool success of the operation
     */
    function registerScheme(
        address _scheme,
        bytes32 _paramsHash,
        bool _canManageSchemes,
        bool _canMakeAvatarCalls
    ) external onlyRegisteredScheme onlyRegisteringSchemes returns (bool) {
        Scheme memory scheme = schemes[_scheme];

        // Add or change the scheme:
        if ((!scheme.isRegistered || !scheme.canManageSchemes) && _canManageSchemes) {
            schemesWithManageSchemesPermission = schemesWithManageSchemesPermission.add(1);
        } else if (scheme.canManageSchemes && !_canManageSchemes) {
            require(
                schemesWithManageSchemesPermission > 1,
                "DAOController: Cannot disable canManageSchemes property from the last scheme with manage schemes permissions"
            );
            schemesWithManageSchemesPermission = schemesWithManageSchemesPermission.sub(1);
        }

        schemes[_scheme] = Scheme({
            paramsHash: _paramsHash,
            isRegistered: true,
            canManageSchemes: _canManageSchemes,
            canMakeAvatarCalls: _canMakeAvatarCalls
        });

        emit RegisterScheme(msg.sender, _scheme);

        return true;
    }

    /**
     * @dev unregister a scheme
     * @param _scheme the address of the scheme
     * @return bool success of the operation
     */
    function unregisterScheme(address _scheme) external onlyRegisteredScheme onlyRegisteringSchemes returns (bool) {
        Scheme memory scheme = schemes[_scheme];

        //check if the scheme is registered
        if (_isSchemeRegistered(_scheme) == false) {
            return false;
        }

        if (scheme.canManageSchemes) {
            require(
                schemesWithManageSchemesPermission > 1,
                "DAOController: Cannot unregister last scheme with manage schemes permission"
            );
            schemesWithManageSchemesPermission = schemesWithManageSchemesPermission.sub(1);
        }

        emit UnregisterScheme(msg.sender, _scheme);

        delete schemes[_scheme];
        return true;
    }

    /**
     * @dev perform a generic call to an arbitrary contract
     * @param _contract  the contract's address to call
     * @param _data ABI-encoded contract call to call `_contract` address.
     * @param _avatar the controller's avatar address
     * @param _value value (ETH) to transfer with the transaction
     * @return bool -success
     *         bytes  - the return value of the called _contract's function.
     */
    function avatarCall(
        address _contract,
        bytes calldata _data,
        DAOAvatar _avatar,
        uint256 _value
    ) external onlyRegisteredScheme onlyAvatarCallScheme returns (bool, bytes memory) {
        return _avatar.executeCall(_contract, _data, _value);
    }

    /**
     * @dev Adds a proposal to the active proposals list
     * @param _proposalId  the proposalId
     */
    function startProposal(bytes32 _proposalId) external onlyRegisteredScheme {
        // TODO: ask Augusto why this next require is not a good option as mentioned at the issue:
        // "Check that a proposal ID is not already used by another scheme when calling the startProposal
        // function is not a good solution, because it will allow a scheme to block proposals from another scheme"
        // https://github.com/DXgovernance/dxdao-contracts/issues/233
        // How this will allow "blocking" proposals from another scheme??
        require(schemeOfProposal[_proposalId] == address(0), "DAOController: _proposalId used by other scheme");
        activeProposals.add(_proposalId);
        schemeOfProposal[_proposalId] = msg.sender;
    }

    /**
     * @dev Moves a proposal from the active proposals list to the inactive list
     * @param _proposalId  the proposalId
     */
    function endProposal(bytes32 _proposalId) external {
        require(
            schemeOfProposal[_proposalId] == msg.sender,
            "DAOController: Sender is not the scheme that originally started the proposal"
        );
        require(
            schemes[msg.sender].isRegistered ||
                (!schemes[schemeOfProposal[_proposalId]].isRegistered && activeProposals.contains(_proposalId)),
            "DAOController: Sender is not a registered scheme or proposal is not active"
        );
        activeProposals.remove(_proposalId);
        inactiveProposals.add(_proposalId);
    }

    /**
     * @dev Burns dao reputation
     * @param _amount  the amount of reputation to burn
     * @param _account  the account to burn reputation from
     */
    function burnReputation(uint256 _amount, address _account) external onlyRegisteredScheme returns (bool) {
        return reputationToken.burn(_account, _amount);
    }

    /**
     * @dev Mints dao reputation
     * @param _amount  the amount of reputation to mint
     * @param _account  the account to mint reputation from
     */
    function mintReputation(uint256 _amount, address _account) external onlyRegisteredScheme returns (bool) {
        return reputationToken.mint(_account, _amount);
    }

    function isSchemeRegistered(address _scheme) external view returns (bool) {
        return _isSchemeRegistered(_scheme);
    }

    function getSchemeParameters(address _scheme) external view returns (bytes32) {
        return schemes[_scheme].paramsHash;
    }

    function getSchemeCanManageSchemes(address _scheme) external view returns (bool) {
        return schemes[_scheme].canManageSchemes;
    }

    function getSchemeCanMakeAvatarCalls(address _scheme) external view returns (bool) {
        return schemes[_scheme].canMakeAvatarCalls;
    }

    function getSchemesCountWithManageSchemesPermissions() external view returns (uint256) {
        return schemesWithManageSchemesPermission;
    }

    function _isSchemeRegistered(address _scheme) private view returns (bool) {
        return (schemes[_scheme].isRegistered);
    }

    /**
     * @dev Returns array of active proposals
     * @param _start index to start batching (included).
     * @param _end last index of batch (included). Zero will default to last element from the list
     * @param _proposals EnumerableSetUpgradeable set of proposals
     * @return proposalsArray with proposals list.
     */
    function _getProposalsBatchRequest(
        uint256 _start,
        uint256 _end,
        EnumerableSetUpgradeable.Bytes32Set storage _proposals
    ) internal view returns (ProposalAndScheme[] memory proposalsArray) {
        uint256 totalCount = uint256(_proposals.length());
        require(_start < totalCount, "DAOController: _start cannot be bigger than proposals list length");
        require(_end < totalCount, "DAOController: _end cannot be bigger than proposals list length");

        uint256 end = _end == 0 ? totalCount.sub(1) : _end;
        uint256 returnCount = end.sub(_start).add(1);

        proposalsArray = new ProposalAndScheme[](returnCount);
        uint256 i = 0;
        for (i; i < returnCount; i++) {
            proposalsArray[i].proposalId = _proposals.at(i.add(_start));
            proposalsArray[i].scheme = schemeOfProposal[_proposals.at(i.add(_start))];
        }
        return proposalsArray;
    }

    /**
     * @dev Returns array of active proposals
     * @param _start index to start batching (included).
     * @param _end last index of batch (included). Zero will return all
     * @return activeProposalsArray with active proposals list.
     */
    function getActiveProposals(uint256 _start, uint256 _end)
        external
        view
        returns (ProposalAndScheme[] memory activeProposalsArray)
    {
        return _getProposalsBatchRequest(_start, _end, activeProposals);
    }

    /**
     * @dev Returns array of inactive proposals
     * @param _start index to start batching
     * @param _end last index of batch
     */
    function getInactiveProposals(uint256 _start, uint256 _end)
        external
        view
        returns (ProposalAndScheme[] memory inactiveProposalsArray)
    {
        return _getProposalsBatchRequest(_start, _end, inactiveProposals);
    }

    function getDaoReputation() external view returns (DAOReputation) {
        return reputationToken;
    }

    /**
     * @dev Returns the amount of active proposals
     */
    function getActiveProposalsCount() public view returns (uint256) {
        return activeProposals.length();
    }

    /**
     * @dev Returns the amount of inactive proposals
     */
    function getInactiveProposalsCount() public view returns (uint256) {
        return inactiveProposals.length();
    }
}
