pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "../interfaces/IERC721.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IAllowanceTransfer.sol";
import "../impermax-v3-core/interfaces/IPoolToken.sol";
import "./TransferHelper.sol";

library ImpermaxPermit {

	address constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
	
	enum PermitType {
		PERMIT1,
		PERMIT_NFT,
		PERMIT2_SINGLE,
		PERMIT2_BATCH
	}
	struct Permit {
		PermitType permitType;
		bytes permitData;
		bytes signature;
	}
	struct Permit1Data {
		address token;
		uint amount;
		uint deadline;
	}
	struct PermitNftData {
		address erc721;
		uint tokenId;
		uint deadline;
	}
	
	bytes32 constant UPPER_BIT_MASK = (0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
	function decodeSignature(bytes memory signature) private pure returns (bytes32 r, bytes32 s, uint8 v) {
		if (signature.length == 65) {
			(r, s) = abi.decode(signature, (bytes32, bytes32));
			v = uint8(signature[64]);
		} else if (signature.length == 64) {
			// EIP-2098
			bytes32 vs;
			(r, vs) = abi.decode(signature, (bytes32, bytes32));
			s = vs & UPPER_BIT_MASK;
			v = uint8(uint256(vs >> 255)) + 27;
		} else {
			revert("ImpermaxRouter: INVALID_SIGNATURE_LENGTH");
		}
	}
		
	function permit1(
		address token, 
		uint amount, 
		uint deadline,
		bytes memory signature
	) private {	
		(bytes32 r, bytes32 s, uint8 v) = decodeSignature(signature);
		IPoolToken(token).permit(msg.sender, address(this), amount, deadline, v, r, s);
	}
	
	function permitNft(
		address erc721, 
		uint tokenId, 
		uint deadline,
		bytes memory signature
	) private {
		(bytes32 r, bytes32 s, uint8 v) = decodeSignature(signature);
		IERC721(erc721).permit(address(this), tokenId, deadline, v, r, s);
	}
	
	function executePermit(Permit memory permit) internal {
		if (permit.permitType == PermitType.PERMIT1) {
			Permit1Data memory decoded = abi.decode(permit.permitData, (Permit1Data));
			permit1(
				decoded.token,
				decoded.amount,
				decoded.deadline,
				permit.signature
			);
		}
		else if (permit.permitType == PermitType.PERMIT_NFT) {
			PermitNftData memory decoded = abi.decode(permit.permitData, (PermitNftData));
			permitNft(
				decoded.erc721,
				decoded.tokenId,
				decoded.deadline,
				permit.signature
			);
		}
		else if (permit.permitType == PermitType.PERMIT2_SINGLE) {
			IAllowanceTransfer.PermitSingle memory decoded = abi.decode(permit.permitData, (IAllowanceTransfer.PermitSingle));
			IAllowanceTransfer(PERMIT2_ADDRESS).permit(msg.sender, decoded, permit.signature);
		}
		else if (permit.permitType == PermitType.PERMIT2_BATCH) {
			IAllowanceTransfer.PermitBatch memory decoded = abi.decode(permit.permitData, (IAllowanceTransfer.PermitBatch));
			IAllowanceTransfer(PERMIT2_ADDRESS).permit(msg.sender, decoded, permit.signature);
		}
		else revert("ImpermaxRouter: INVALID_PERMIT");
	}
	
	function executePermits(Permit[] memory permits) internal {
		for (uint i = 0; i < permits.length; i++) {
			executePermit(permits[i]);
		}
	}
	
	function safeTransferFrom(address token, address from, address to, uint256 value) internal {
		uint allowance = IERC20(token).allowance(from, address(this));
		if (allowance >= value) return TransferHelper.safeTransferFrom(token, from, to, value);
		IAllowanceTransfer(PERMIT2_ADDRESS).transferFrom(from, to, safe160(value), token);
	}
	
    function safe160(uint n) internal pure returns (uint160) {
        require(n < 2**160, "Impermax: SAFE160");
        return uint160(n);
    }
}