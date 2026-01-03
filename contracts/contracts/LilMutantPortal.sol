// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ONFT721Adapter } from "@layerzerolabs/onft-evm/contracts/onft721/ONFT721Adapter.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @title LilMutantPortal
 * @author marvpeggy
 * @notice LayerZero ONFT721Adapter implementation for cross-chain NFT bridging
 * @dev Implements lock-and-mint mechanism for Lil Mutant NFTs on Ethereum mainnet.
 *      Original NFTs are locked in this contract while wrapped versions exist on destination chains.
 *      Includes pausable functionality, reentrancy protection, and emergency recovery mechanisms.
 */
contract LilMutantPortal is ONFT721Adapter, Pausable, ReentrancyGuard {
    /// @notice Tracks tokens currently locked in the portal
    mapping(uint256 => bool) public isTokenLocked;
    
    /// @notice Maps locked tokens to their original owners
    mapping(uint256 => address) public originalOwner;
    
    /// @dev Reference to the underlying ERC721 token contract
    IERC721 private immutable nftToken;
    
    /// @notice Platform fee for bridging to Base or ApeChain (0.00015 ETH)
    uint256 public platformFee = 0.00015 ether;
    
    /// @notice Accumulated platform fees
    uint256 public accumulatedFees;
    
    // Events
    event NFTLocked(uint256 indexed tokenId, address indexed owner, uint32 destinationChain);
    event NFTUnlocked(uint256 indexed tokenId, address indexed owner);
    event EmergencyReturn(uint256 indexed tokenId, address indexed to);
    event PlatformFeeCollected(address indexed from, uint256 amount, uint32 destinationChain);
    event PlatformFeeWithdrawn(address indexed to, uint256 amount);
    event PlatformFeeUpdated(uint256 newFee);
    
    /**
     * @dev Constructor for the ONFT721Adapter
     * @param _token The Lil Mutant NFT contract address on Ethereum
     * @param _lzEndpoint The LayerZero endpoint address (0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675 on mainnet)
     * @param _delegate The delegate capable of making OApp configurations
     */
    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) ONFT721Adapter(_token, _lzEndpoint, _delegate) {
        nftToken = IERC721(_token);
    }
    
    /**
     * @dev Locks NFT before cross-chain transfer
     */
    function _debit(
        address _from,
        uint256 _tokenId,
        uint32 _dstEid
    ) internal virtual override whenNotPaused nonReentrant {
        // Collect platform fee when sending FROM Ethereum TO other chains
        require(msg.value >= platformFee, "Bridge: Insufficient platform fee sent");
        
        accumulatedFees += platformFee;
        emit PlatformFeeCollected(_from, platformFee, _dstEid);
        
        isTokenLocked[_tokenId] = true;
        originalOwner[_tokenId] = _from;
        
        super._debit(_from, _tokenId, _dstEid);
        
        emit NFTLocked(_tokenId, _from, _dstEid);
    }
    
    /**
     * @dev LayerZero OAppSender requires msg.value to cover the LayerZero fee.
     * This contract also collects a platform fee, so we override native payment logic to:
     * - keep the platform fee in this contract
     * - forward the remainder (including any user buffer) to the endpoint
     * - endpoint refunds any excess to the refund address passed into `send()`
     */
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        // Must cover both the platform fee AND the LayerZero fee
        if (msg.value < platformFee + _nativeFee) revert NotEnoughNative(msg.value);
        // Forward everything except the platform fee to LayerZero Endpoint
        return msg.value - platformFee;
    }
    
    /**
     * @dev Unlocks NFT after cross-chain burn
     */
    function _credit(
        address _to,
        uint256 _tokenId,
        uint32 _srcEid
    ) internal virtual override whenNotPaused nonReentrant {
        require(_to != address(0), "Bridge: Cannot unlock to zero address");
        require(isTokenLocked[_tokenId], "Bridge: Token not locked in portal");
        
        isTokenLocked[_tokenId] = false;
        delete originalOwner[_tokenId];
        
        super._credit(_to, _tokenId, _srcEid);
        
        emit NFTUnlocked(_tokenId, _to);
    }
    
    /**
     * @notice Pauses bridging operations
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Resumes bridging operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Emergency function to recover locked NFTs
     * @param tokenId The token ID to recover
     * @param to The recipient address
     */
    function emergencyReturnNFT(uint256 tokenId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Emergency: Cannot send to zero address");
        require(isTokenLocked[tokenId], "Emergency: Token not locked in portal");
        require(nftToken.ownerOf(tokenId) == address(this), "Emergency: Portal doesn't own token");
        
        nftToken.transferFrom(address(this), to, tokenId);
        
        isTokenLocked[tokenId] = false;
        delete originalOwner[tokenId];
        
        emit EmergencyReturn(tokenId, to);
    }
    
    /**
     * @notice Checks if a token is currently locked in the portal
     * @param tokenId The token ID to query
     * @return bool Lock status
     */
    function isLocked(uint256 tokenId) external view returns (bool) {
        return isTokenLocked[tokenId];
    }
    
    /**
     * @notice Returns the original owner of a locked token
     * @param tokenId The token ID to query
     * @return address Original owner address
     */
    function getOriginalOwner(uint256 tokenId) external view returns (address) {
        return originalOwner[tokenId];
    }
    
    /**
     * @notice Returns the pause status of the contract
     * @return bool Pause state
     */
    function isPaused() external view returns (bool) {
        return paused();
    }
    
    /**
     * @dev Allows pathway initialization from any source chain
     * @return bool Always returns true to permit cross-chain messaging
     */
    function allowInitializePath(Origin calldata /*origin*/) 
        public 
        view 
        virtual 
        override 
        returns (bool) 
    {
        return true;
    }
    
    /**
     * @notice Updates the platform fee
     * @param newFee The new platform fee in wei
     */
    function setPlatformFee(uint256 newFee) external onlyOwner {
        platformFee = newFee;
        emit PlatformFeeUpdated(newFee);
    }
    
    /**
     * @notice Withdraws platform fees
     * @param to The recipient address
     */
    function withdrawPlatformFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "Withdraw: Cannot send to zero address");
        uint256 amount = accumulatedFees;
        require(amount > 0, "Withdraw: No fees available");
        
        accumulatedFees = 0;
        
        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdraw: ETH transfer failed");
        
        emit PlatformFeeWithdrawn(to, amount);
    }
    
    /**
     * @notice Returns the current platform fee
     * @return uint256 Platform fee in wei
     */
    function getPlatformFee() external view returns (uint256) {
        return platformFee;
    }
    
    /**
     * @notice Returns the accumulated platform fees
     * @return uint256 Accumulated fees in wei
     */
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
    
    /**
     * @dev Allows contract to receive ETH for platform fees
     */
    receive() external payable {}
}
