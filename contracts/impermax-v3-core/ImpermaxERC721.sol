pragma solidity =0.5.16;

import "./libraries/SafeMath.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IERC721Receiver.sol";

contract ImpermaxERC721 is IERC721 {
	using SafeMath for uint;
	
	string public name;
	string public symbol;
	
	mapping(address => uint) public balanceOf;
	mapping(uint256 => address) public ownerOf;
	mapping(uint256 => address) public getApproved;
	mapping(address => mapping(address => bool)) public isApprovedForAll;
	
	bytes32 public DOMAIN_SEPARATOR;
	mapping(uint256 => uint) public nonces;

	constructor() public {}
	
	function _setName(string memory _name, string memory _symbol) internal {
		name = _name;
		symbol = _symbol;
		
		uint chainId;
		assembly {
			chainId := chainid
		}
		DOMAIN_SEPARATOR = keccak256(
			abi.encode(
				keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
				keccak256(bytes(_name)),
				keccak256(bytes("1")),
				chainId,
				address(this)
			)
		);
	}
	
	function _isAuthorized(address owner, address operator, uint256 tokenId) internal view returns (bool) {
		return operator != address(0) && (owner == operator || isApprovedForAll[owner][operator] || getApproved[tokenId] == operator);
	}

	function _checkAuthorized(address owner, address operator, uint256 tokenId) internal view {
		require(_isAuthorized(owner, operator, tokenId), "ImpermaxERC721: UNAUTHORIZED");
	}

	function _update(address to, uint256 tokenId, address auth) internal returns (address from) {
		from = ownerOf[tokenId];
		if (auth != address(0)) _checkAuthorized(from, auth, tokenId);

		if (from != address(0)) {
			_approve(address(0), tokenId, address(0));
			balanceOf[from] -= 1;
		}

		if (to != address(0)) {
			balanceOf[to] += 1;
		}

		ownerOf[tokenId] = to;
		emit Transfer(from, to, tokenId);
	}
	
	function _mint(address to, uint256 tokenId) internal {
		require(to != address(0), "ImpermaxERC721: INVALID_RECEIVER");
		address previousOwner = _update(to, tokenId, address(0));
		require(previousOwner == address(0), "ImpermaxERC721: INVALID_SENDER");
	}
	function _safeMint(address to, uint256 tokenId, bytes memory data) internal {
		_mint(to, tokenId);
		_checkOnERC721Received(address(0), to, tokenId, data);
	}
	
	function _burn(uint256 tokenId) internal {
		address previousOwner = _update(address(0), tokenId, address(0));
		require(previousOwner != address(0), "ImpermaxERC721: NONEXISTENT_TOKEN");
	}
	
	function _transfer(address from, address to, uint256 tokenId, address auth) internal {
		require(to != address(0), "ImpermaxERC721: INVALID_RECEIVER");
		address previousOwner = _update(to, tokenId, auth);
		require(previousOwner != address(0), "ImpermaxERC721: NONEXISTENT_TOKEN");
		require(previousOwner == from, "ImpermaxERC721: INCORRECT_OWNER");
	}
	
	function _safeTransfer(address from, address to, uint256 tokenId, address auth) internal {
		_safeTransfer(from, to, tokenId, "", auth);
	}
	function _safeTransfer(address from, address to, uint256 tokenId, bytes memory data, address auth) internal {
		_transfer(from, to, tokenId, auth);
		_checkOnERC721Received(from, to, tokenId, data);
	}

	function _approve(address to, uint256 tokenId, address auth) internal {
		address owner = _requireOwned(tokenId);
		require(auth == address(0) || auth == owner || isApprovedForAll[owner][auth], "ImpermaxERC721: INVALID_APPROVER");
		getApproved[tokenId] = to;
		emit Approval(owner, to, tokenId);
	}

	function _setApprovalForAll(address owner, address operator, bool approved) internal {
		require(operator != address(0), "ImpermaxERC721: INVALID_OPERATOR");
		isApprovedForAll[owner][operator] = approved;
		emit ApprovalForAll(owner, operator, approved);
	}
	
	function _requireOwned(uint256 tokenId) internal view returns (address) {
		address owner = ownerOf[tokenId];
		require(owner != address(0), "ImpermaxERC721: NONEXISTENT_TOKEN");
		return owner;
	}
	
	function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) internal {
		if (isContract(to)) {
			bytes4 retval = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
			require(retval == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")), "ImpermaxERC721: INVALID_RECEIVER");
		}
	}
	
	function approve(address to, uint256 tokenId) external {
		_approve(to, tokenId, msg.sender);
	}
	
	function setApprovalForAll(address operator, bool approved) external {
		_setApprovalForAll(msg.sender, operator, approved);
	}
	
	function transferFrom(address from, address to, uint256 tokenId) external {
		_transfer(from, to, tokenId, msg.sender);
	}

	function safeTransferFrom(address from, address to, uint256 tokenId) external {
		_safeTransfer(from, to, tokenId, msg.sender);
	}
	
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
		_safeTransfer(from, to, tokenId, data, msg.sender);
	}
	
	function _checkSignature(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s, bytes32 typehash) internal {
		require(deadline >= block.timestamp, "ImpermaxERC721: EXPIRED");
		bytes32 digest = keccak256(
			abi.encodePacked(
				'\x19\x01',
				DOMAIN_SEPARATOR,
				keccak256(abi.encode(typehash, spender, tokenId, nonces[tokenId]++, deadline))
			)
		);
		address owner = ownerOf[tokenId];
		address recoveredAddress = ecrecover(digest, v, r, s);
		require(recoveredAddress != address(0) && recoveredAddress == owner, "ImpermaxERC721: INVALID_SIGNATURE");	
	}

	// keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
	bytes32 public constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;
	function permit(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
		_checkSignature(spender, tokenId, deadline, v, r, s, PERMIT_TYPEHASH);
		_approve(spender, tokenId, address(0));
	}
	
	/* Utilities */
	function isContract(address _addr) private view returns (bool){
		uint32 size;
		assembly {
			size := extcodesize(_addr)
		}
		return (size > 0);
	}
}