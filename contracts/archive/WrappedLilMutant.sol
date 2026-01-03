// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ONFT721 } from "@layerzerolabs/onft-evm/contracts/onft721/ONFT721.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @title WrappedLilMutant
 * @author marvpeggy
 * @notice LayerZero ONFT721 implementation for wrapped NFTs on destination chains
 * @dev Implements burn-and-mint mechanism for Lil Mutant NFTs on Base and ApeChain.
 *      Tokens are minted when originals are locked on Ethereum and burned when returned.
 *      Includes pausable functionality, reentrancy protection, and emergency recovery mechanisms.
 */
contract WrappedLilMutant is ONFT721, Pausable, ReentrancyGuard {
    
    /// @notice Platform fee for bridging from Base to Ethereum (0.00015 ETH)
    uint256 public platformFeeETH = 0.00015 ether;
    
    /// @notice Platform fee for bridging from ApeChain to Ethereum (2 APE)
    uint256 public platformFeeAPE = 2 ether;
    
    /// @notice Indicates if this is deployed on ApeChain (true) or Base (false)
    bool public isApeChain;
    
    /// @notice Accumulated platform fees
    uint256 public accumulatedFees;
    
    event EmergencyWithdraw(address indexed owner, uint256 indexed tokenId);
    event PlatformFeeCollected(address indexed from, uint256 amount, uint32 destinationChain);
    event PlatformFeeWithdrawn(address indexed to, uint256 amount);
    event PlatformFeeUpdated(uint256 newFeeETH, uint256 newFeeAPE);
    event ChainTypeSet(bool isApeChain);
    
    /**
     * @dev Initializes the ONFT721 contract with LayerZero configuration
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _lzEndpoint LayerZero endpoint address for the deployed chain
     * @param _delegate Address authorized to configure LayerZero settings
     * @param _isApeChain True if deploying on ApeChain, false for Base
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate,
        bool _isApeChain
    ) ONFT721(_name, _symbol, _lzEndpoint, _delegate) {
        isApeChain = _isApeChain;
        emit ChainTypeSet(_isApeChain);
    }
    
    /**
     * @dev Burns NFT before cross-chain transfer. Overrides parent to add
     *      pause functionality, reentrancy protection, and platform fee collection.
     */
    function _debit(
        address _from,
        uint256 _tokenId,
        uint32 _dstEid
    ) internal virtual override whenNotPaused nonReentrant {
        // Collect platform fee when sending FROM Base/ApeChain TO Ethereum
        uint256 requiredFee = isApeChain ? platformFeeAPE : platformFeeETH;
        
        if (msg.value >= requiredFee) {
            accumulatedFees += requiredFee;
            emit PlatformFeeCollected(_from, requiredFee, _dstEid);
        }
        
        super._debit(_from, _tokenId, _dstEid);
    }
    
    /**
     * @dev Mints NFT after receiving cross-chain message. Overrides parent to add
     *      pause functionality and reentrancy protection.
     */
    function _credit(
        address _to,
        uint256 _tokenId,
        uint32 _srcEid
    ) internal virtual override whenNotPaused nonReentrant {
        super._credit(_to, _tokenId, _srcEid);
    }
    
    /**
     * @notice Pauses all bridging operations
     * @dev Only callable by contract owner. Trading on this chain remains unaffected.
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Resumes all bridging operations
     * @dev Only callable by contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Emergency function to recover NFTs held by contract
     * @dev Only callable by contract owner
     * @param tokenId The token ID to recover
     * @param to The recipient address
     */
    function emergencyWithdraw(uint256 tokenId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Cannot send to zero address");
        require(_ownerOf(tokenId) == address(this), "Token not held by contract");
        
        _transfer(address(this), to, tokenId);
        emit EmergencyWithdraw(to, tokenId);
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
     * @notice Updates the platform fees for bridging
     * @dev Only callable by contract owner
     * @param newFeeETH The new platform fee in ETH (for Base)
     * @param newFeeAPE The new platform fee in APE (for ApeChain)
     */
    function setPlatformFees(uint256 newFeeETH, uint256 newFeeAPE) external onlyOwner {
        platformFeeETH = newFeeETH;
        platformFeeAPE = newFeeAPE;
        emit PlatformFeeUpdated(newFeeETH, newFeeAPE);
    }
    
    /**
     * @notice Withdraws accumulated platform fees
     * @dev Only callable by contract owner
     * @param to The recipient address for the fees
     */
    function withdrawPlatformFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "Cannot withdraw to zero address");
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees to withdraw");
        
        accumulatedFees = 0;
        
        (bool success, ) = to.call{value: amount}("");
        require(success, "Fee withdrawal failed");
        
        emit PlatformFeeWithdrawn(to, amount);
    }
    
    /**
     * @notice Returns the current platform fee for this chain
     * @return uint256 Platform fee in native token (ETH for Base, APE for ApeChain)
     */
    function getPlatformFee() external view returns (uint256) {
        return isApeChain ? platformFeeAPE : platformFeeETH;
    }
    
    /**
     * @notice Returns the accumulated platform fees
     * @return uint256 Accumulated fees in native token
     */
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
    
    /**
     * @notice Returns whether this contract is deployed on ApeChain
     * @return bool True if ApeChain, false if Base
     */
    function getChainType() external view returns (bool) {
        return isApeChain;
    }
    
    /**
     * @dev Allows contract to receive native tokens (ETH/APE) for platform fees
     */
    receive() external payable {}
}
