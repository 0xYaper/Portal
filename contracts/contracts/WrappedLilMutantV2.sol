// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ONFT721 } from "@layerzerolabs/onft-evm/contracts/onft721/ONFT721.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC165 } from "@openzeppelin/contracts/interfaces/IERC165.sol";
import { ICreatorToken } from "@limitbreak/creator-token-standards/src/interfaces/ICreatorToken.sol";
import { ITransferValidator } from "@limitbreak/creator-token-standards/src/interfaces/ITransferValidator.sol";

/**
 * @title WrappedLilMutantV2
 * @author marvpeggy
 * @notice Wrapped ONFT used for the portal bridge (Base / ApeChain).
 * @dev ERC2981 royalties + optional transfer validation for marketplace fills.
 *      Mint/burn (LayerZero credit/debit) bypasses validation.
 */
contract WrappedLilMutantV2 is ONFT721, IERC2981, ICreatorToken, Pausable, ReentrancyGuard {
    using Strings for uint256;
    
    /// @notice Platform fee for bridging from Base to Ethereum (0.00015 ETH)
    uint256 public platformFeeETH = 0.00015 ether;
    
    /// @notice Platform fee for bridging from ApeChain to Ethereum (2 APE)
    uint256 public platformFeeAPE = 2 ether;
    
    /// @notice Indicates if this is deployed on ApeChain (true) or Base (false)
    bool public isApeChain;
    
    /// @notice Accumulated platform fees
    uint256 public accumulatedFees;
    
    /// @notice Royalty fee in basis points (500 = 5%)
    uint96 public royaltyFeeNumerator = 500;
    
    /// @notice Royalty receiver address
    address public royaltyReceiver;
    
    /// @notice Transfer validator for OpenSea enforcement (optional)
    address public transferValidator;
    
    event EmergencyWithdraw(address indexed owner, uint256 indexed tokenId);
    event PlatformFeeCollected(address indexed from, uint256 amount, uint32 destinationChain);
    event PlatformFeeWithdrawn(address indexed to, uint256 amount);
    event PlatformFeeUpdated(uint256 newFeeETH, uint256 newFeeAPE);
    event ChainTypeSet(bool isApeChain);
    event RoyaltyInfoUpdated(address receiver, uint96 feeNumerator);
    
    /**
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _lzEndpoint LayerZero endpoint address
     * @param _delegate Delegate for OApp configurations
     * @param _isApeChain True for ApeChain, false for Base
     * @param _royaltyReceiver Royalty receiver address
     * @param _transferValidator Transfer validator address (use address(0) to disable)
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate,
        bool _isApeChain,
        address _royaltyReceiver,
        address _transferValidator
    ) ONFT721(_name, _symbol, _lzEndpoint, _delegate) {
        isApeChain = _isApeChain;
        royaltyReceiver = _royaltyReceiver;
        transferValidator = _transferValidator;
        emit ChainTypeSet(_isApeChain);
        emit RoyaltyInfoUpdated(_royaltyReceiver, royaltyFeeNumerator);
    }
    
    /**
     * @dev Burns NFT for cross-chain transfer with platform fee collection
     */
    function _debit(
        address _from,
        uint256 _tokenId,
        uint32 _dstEid
    ) internal virtual override whenNotPaused nonReentrant {
        // Collect platform fee when sending FROM Base/ApeChain TO Ethereum
        uint256 requiredFee = isApeChain ? platformFeeAPE : platformFeeETH;
        
        require(msg.value >= requiredFee, "Bridge: Insufficient platform fee sent");
        
        accumulatedFees += requiredFee;
        emit PlatformFeeCollected(_from, requiredFee, _dstEid);
        
        super._debit(_from, _tokenId, _dstEid);
    }
    
    /**
     * @dev LayerZero OAppSender requires msg.value to cover the LayerZero fee.
     * This contract also collects a platform fee, so we override native payment logic to:
     * - keep the platform fee in this contract
     * - forward the remainder (including any user buffer) to the endpoint
     * - endpoint refunds any excess to the refund address passed into `send()`
     */
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        uint256 requiredFee = isApeChain ? platformFeeAPE : platformFeeETH;
        if (msg.value < requiredFee + _nativeFee) revert NotEnoughNative(msg.value);
        return msg.value - requiredFee;
    }
    
    /**
     * @dev Mints NFT after receiving cross-chain message
     */
    function _credit(
        address _to,
        uint256 _tokenId,
        uint32 _srcEid
    ) internal virtual override whenNotPaused nonReentrant {
        require(_to != address(0), "Bridge: Cannot mint to zero address");
        
        super._credit(_to, _tokenId, _srcEid);
    }
    
    /**
     * @dev Validates transfers through OpenSea validator (if set)
     * @notice Free transfers when validator is not set (address(0))
     *         Bridge operations always bypass validation
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        
        // Only validate if:
        // - validator is set
        // - not a mint/burn (from/to non-zero)
        // - operator transfer (msg.sender != from) so normal owner-initiated transfers stay unrestricted
        //   and LayerZero mint/burn paths remain unaffected.
        if (
            transferValidator != address(0) &&
            from != address(0) &&
            to != address(0) &&
            msg.sender != from
        ) {
            ITransferValidator(transferValidator).validateTransfer(msg.sender, from, to, tokenId);
        }
        
        return super._update(to, tokenId, auth);
    }
    
    /**
     * @notice ERC2981 royalty info
     * @param salePrice Sale price
     * @return receiver Royalty receiver
     * @return royaltyAmount Royalty amount
     */
    function royaltyInfo(
        uint256 /* tokenId */,
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        receiver = royaltyReceiver;
        royaltyAmount = (salePrice * royaltyFeeNumerator) / 10000;
    }
    
    /**
     * @dev Supports ERC721, ERC2981, and ICreatorToken interfaces
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721, IERC165) returns (bool) {
        return 
            interfaceId == type(IERC2981).interfaceId || 
            interfaceId == type(ICreatorToken).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    /**
     * @notice Get the transfer validator address
     * @return validator The validator address (address(0) if not set)
     */
    function getTransferValidator() external view override returns (address) {
        return transferValidator;
    }
    
    /**
     * @notice Get the transfer validation function signature
     * @return functionSignature The function selector for validateTransfer
     * @return isViewFunction Whether the function is view-only
     */
    function getTransferValidationFunction() external pure override returns (bytes4, bool) {
        return (bytes4(0xcaee23ea), true); // validateTransfer(address,address,address,uint256)
    }
    
    /**
     * @notice Set the transfer validator (OpenSea enforcement)
     * @param validator Validator address (use address(0) to disable enforcement)
     */
    function setTransferValidator(address validator) external override onlyOwner {
        address old = transferValidator;
        transferValidator = validator;
        emit TransferValidatorUpdated(old, validator);
    }

    /**
     * @notice Token URI always uses `<baseURI><tokenId>.json`
     * @dev This enforces JSON metadata naming without requiring callers to include ".json" in the base URI.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = _baseURI();
        return bytes(base).length > 0 ? string(abi.encodePacked(base, tokenId.toString(), ".json")) : "";
    }
    
    function setRoyaltyInfo(address _royaltyReceiver, uint96 _royaltyFeeNumerator) external onlyOwner {
        require(_royaltyFeeNumerator <= 10000, "Royalty: Fee cannot exceed 100%");
        require(_royaltyReceiver != address(0), "Royalty: Receiver cannot be zero address");
        royaltyReceiver = _royaltyReceiver;
        royaltyFeeNumerator = _royaltyFeeNumerator;
        emit RoyaltyInfoUpdated(_royaltyReceiver, _royaltyFeeNumerator);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw(uint256 tokenId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Emergency: Cannot send to zero address");
        require(_ownerOf(tokenId) == address(this), "Emergency: Token not held by contract");
        
        _transfer(address(this), to, tokenId);
        emit EmergencyWithdraw(to, tokenId);
    }
    
    function isPaused() external view returns (bool) {
        return paused();
    }
    
    function allowInitializePath(Origin calldata /*origin*/) 
        public 
        view 
        virtual 
        override 
        returns (bool) 
    {
        return true;
    }
    
    function setPlatformFees(uint256 newFeeETH, uint256 newFeeAPE) external onlyOwner {
        platformFeeETH = newFeeETH;
        platformFeeAPE = newFeeAPE;
        emit PlatformFeeUpdated(newFeeETH, newFeeAPE);
    }
    
    function withdrawPlatformFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "Withdraw: Cannot send to zero address");
        uint256 amount = accumulatedFees;
        require(amount > 0, "Withdraw: No fees available");
        
        accumulatedFees = 0;
        
        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdraw: ETH transfer failed");
        
        emit PlatformFeeWithdrawn(to, amount);
    }
    
    function getPlatformFee() external view returns (uint256) {
        return isApeChain ? platformFeeAPE : platformFeeETH;
    }
    
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
    
    function getChainType() external view returns (bool) {
        return isApeChain;
    }
    
    receive() external payable {}
}
