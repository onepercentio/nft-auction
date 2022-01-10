// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

/**
 * @dev Adaptation of OpenZeppelin's ERC20Permit
 */
abstract contract NFTAuctionPermit is EIP712Upgradeable {

    mapping(address => mapping(bytes32 => bool)) internal _authorizationStates;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    // solhint-disable-next-line var-name-mixedcase
    bytes32 private constant _AUCTION_TYPEHASH = keccak256("AuthorizedAuction(uint256 amount,uint256 tokenId,uint128 bidIncreasePercentage,uint256 minPrice,uint256 start,uint256 end,address nftContractAddress,address erc20Token,address nftSeller)");
    bytes32 private constant _BID_TYPEHASH = keccak256("AuthorizedBid(uint256 _auctionId,address _erc20Token,uint256 _tokenAmount,address _bidder,bytes32 _nonce,uint256 _deadline)");

    struct NewAuctionRequest {
        address nftContractAddress;
        uint256 tokenId;
        uint256 amount;
        address erc20Token;
        uint256 minPrice;
        uint256 start;
        uint256 end;
        uint32 bidIncreasePercentage;
        address[] feeRecipients;
        uint32[] feePercentages;
    }

    /**
     * @dev See {IERC20Permit-permit}.
     */
    function authorizedAuctionCreation(
        NewAuctionRequest calldata _newAuction,
        address _seller,
        bytes32 _nonce,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp <= _deadline, "NFTAuctionPermit: expired deadline");
        require(
            !_authorizationStates[_seller][_nonce],
            "NFTAuctionPermit: authorization is used"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                _AUCTION_TYPEHASH,
                _newAuction.amount,
                _newAuction.tokenId,
                _newAuction.bidIncreasePercentage,
                _newAuction.minPrice,
                _newAuction.start,
                _newAuction.end,
                _newAuction.nftContractAddress,
                _newAuction.erc20Token,
                _seller,
                _nonce,
                _deadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSAUpgradeable.recover(hash, _v, _r, _s);
        require(signer == _seller, "NFTAuctionPermit: invalid signature");

        _authorizationStates[_seller][_nonce] = true;

        _createAuction(_newAuction, _seller);

        emit AuthorizationUsed(_seller, _nonce);
    }

    /**
     * @dev See {IERC20Permit-permit}.
     */
    function authorizedBid(
        uint256 _auctionId,
        address _erc20Token,
        uint256 _tokenAmount,
        address _bidder,
        bytes32 _nonce,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp <= _deadline, "NFTAuctionPermit: expired deadline");
        require(
            !_authorizationStates[_bidder][_nonce],
            "NFTAuctionPermit: authorization is used"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                _BID_TYPEHASH,
                _auctionId,
                _erc20Token,
                _tokenAmount,
                _bidder,
                _nonce,
                _deadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSAUpgradeable.recover(hash, _v, _r, _s);
        require(signer == _bidder, "NFTAuctionPermit: invalid signature");

        _authorizationStates[_bidder][_nonce] = true;

        _bid(_auctionId, _erc20Token, _tokenAmount, _bidder);

        emit AuthorizationUsed(_bidder, _nonce);
    }

    function _bid(
        uint256 _auctionId,
        address _erc20Token,
        uint256 _tokenAmount,
        address _bidder
    ) internal virtual;

    function _createAuction(
        NewAuctionRequest calldata _newAuction,
        address _seller
    ) internal virtual;

    function authorizationState(address authorizer, bytes32 nonce)
        external
        view
        returns (bool)
    {
        return _authorizationStates[authorizer][nonce];
    }

    /**
     * @dev See {IERC20Permit-DOMAIN_SEPARATOR}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

}
