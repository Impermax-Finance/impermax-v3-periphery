const {
	bnMantissa,
	BN,
	expectEvent,
} = require('./JS');
const {
	address,
	encode,
	encodePacked,
} = require('./Ethereum');
const { hexlify, keccak256, toUtf8Bytes } = require('ethers/utils');
const { ecsign } = require('ethereumjs-util');

//UTILITIES

const MAX_UINT_256 = (new BN(2)).pow(new BN(256)).sub(new BN(1));
const MAX_UINT_48 = (new BN(2)).pow(new BN(48)).sub(new BN(1));
const DEADLINE = MAX_UINT_256;
const EXPIRATION = MAX_UINT_48;

const Permit2 = artifacts.require('IAllowanceTransfer');
const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

const permitType = {
	PERMIT: 1,
	BORROW_PERMIT: 2,
	NFT_PERMIT: 3,
	PERMIT2_SINGLE: 4,
	PERMIT2_BATCH: 5
};

// TYPEHASHes
const PERMIT_TYPEHASH = keccak256(
	toUtf8Bytes('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
);
const BORROW_PERMIT_TYPEHASH = keccak256(
	toUtf8Bytes('BorrowPermit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
);
const NFT_PERMIT_TYPEHASH = keccak256(
	toUtf8Bytes('Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)')
);
const PERMIT2_SINGLE_TYPEHASH = keccak256(
	toUtf8Bytes("PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)")
);
const PERMIT2_DETAILS_TYPEHASH = keccak256(
	toUtf8Bytes("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)")
);


const permitGenerator = {
	// Note: activatePermit is false by default. If you want to test the permit you need to configure mnemonic and the chainId
	// to do that run ganache with:
	// ganache-cli --fork.network mainnet -m "excuse dumb consider baby coral write north dilemma winter immense hunt cannon"
	// and check the chainId
	activatePermit: false,
	mnemonic: 'excuse dumb consider baby coral write north dilemma winter immense hunt cannon',
	chainId: '1337',
	PKs: [],
	permit2Contract: null,
	
	// INITIALIZE
	initialize: async () => {
		if (!permitGenerator.activatePermit) return;
		const { mnemonicToSeed } = require('bip39');
		const { hdkey } = require('ethereumjs-wallet');
		const seed = await mnemonicToSeed(permitGenerator.mnemonic);
		const hdk = hdkey.fromMasterSeed(seed);
		for (i = 0; i < 10; i++) {
			const wallet = hdk.derivePath("m/44'/60'/0'/0/"+i).getWallet();
			permitGenerator.PKs[wallet.getAddressString().toLowerCase()] = wallet.getPrivateKey();
		}
		if (permitGenerator.activatePermit) {
			permitGenerator.permit2Contract = await Permit2.at(PERMIT2_ADDRESS);			
		}
	},
	
	// COMMON FUNCTIONS
	_getApprovalDigest: (domainSeparator, hash) => {
		return keccak256(
			encodePacked(
				['bytes1', 'bytes1', 'bytes32', 'bytes32'],
				['0x19', '0x01', domainSeparator, hash]
			)
		);
	},
	_getSignature: (owner, domainSeparator, hash) => {
		const digest = permitGenerator._getApprovalDigest(domainSeparator, hash);
		private_key = permitGenerator.PKs[owner.toLowerCase()];
		if (!private_key) console.error("Wrong mnemonic, can't sign");
		const { v, r, s } = ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(private_key, 'hex'));
		return encodePacked(['bytes32', 'bytes32', 'bytes1'], [hexlify(r), hexlify(s), hexlify(v)]);
	},
	
	// PERMIT CLASSIC 
	_getDomainSeparator: (name, tokenAddress) => keccak256(encode(
		['bytes32', 'bytes32', 'bytes32', 'uint256', 'address'],
		[
			keccak256(toUtf8Bytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
			keccak256(toUtf8Bytes(name)),
			keccak256(toUtf8Bytes('1')),
			permitGenerator.chainId,
			tokenAddress
		]
	)),
	_genericSignature: async (token, owner, encodedParams, fallback) => {
		if (permitGenerator.activatePermit) {
			const name = await token.name();
			const domainSeparator = permitGenerator._getDomainSeparator(name, token.address);
			const hash = keccak256(encodedParams);
			return permitGenerator._getSignature(owner, domainSeparator, hash);
		}
		else {
			await fallback;
			return null;
		}
	},
	_permitSignature: async (token, owner, spender, value, deadline) => permitGenerator._genericSignature(
		token,
		owner,
		encode(
			['bytes32', 'address', 'address', 'uint256', 'uint256', 'uint256'],
			[PERMIT_TYPEHASH, owner, spender, value.toString(), (await token.nonces(owner)).toString(), deadline.toString()]
		),
		token.approve(spender, value, {from: owner})
	),
	_nftPermitSignature: async (token, owner, spender, tokenId, deadline) => permitGenerator._genericSignature(
		token,
		owner,
		encode(
			['bytes32', 'address', 'uint256', 'uint256', 'uint256'],
			[NFT_PERMIT_TYPEHASH, spender, tokenId.toString(), (await token.nonces(tokenId)).toString(), deadline.toString()]
		),
		token.approve(spender, tokenId, {from: owner})
	),
	permit: async (token, owner, spender, value, deadline) => ({
		permitType: '0',
		permitData: encode(['address', 'uint256', 'uint256'], [token.address, value.toString(), deadline.toString()]),
		signature: await permitGenerator._permitSignature(token, owner, spender, value, deadline)
	}),
	nftPermit: async (token, owner, spender, tokenId, deadline) => ({
		permitType: '1',
		permitData: encode(['address', 'uint256', 'uint256'], [token.address, tokenId.toString(), deadline.toString()]),
		signature: await permitGenerator._nftPermitSignature(token, owner, spender, tokenId, deadline)
	}),

	// PERMIT 2
	_getPermit2DomainSeparator: () => keccak256(encode(
		['bytes32', 'bytes32', 'uint256', 'address'],
		[
			keccak256(toUtf8Bytes('EIP712Domain(string name,uint256 chainId,address verifyingContract)')),
			keccak256(toUtf8Bytes('Permit2')),
			permitGenerator.chainId,
			PERMIT2_ADDRESS
		]
	)),

	_permit2SingleSignature: (owner, tokenAddress, value, expiration, nonce, spender, deadline) => {
		const permitDetailsType = 'tuple(address tokenAddress, uint160 amount, uint48 expiration, uint48 nonce)';
		const permitDetails = {
			tokenAddress,
			amount: value.toString(),
			expiration: expiration.toString(),
			nonce: nonce.toString(),
		};
		
		const permitData = encode(
			[permitDetailsType, 'address', 'uint256'],
			[permitDetails, spender, deadline.toString()]
		);
		
		const domainSeparator = permitGenerator._getPermit2DomainSeparator();
		
		const permitHash = keccak256(encode(
			['bytes32', permitDetailsType],
			[PERMIT2_DETAILS_TYPEHASH, permitDetails]
		));
		const hash = keccak256(encode(
			['bytes32', 'bytes32', 'address', 'uint256'],
			[PERMIT2_SINGLE_TYPEHASH, permitHash, spender, deadline.toString()]
		));
		
		const signature = permitGenerator._getSignature(owner, domainSeparator, hash);
		
		return { permitData, signature };
	},
	
	permit2Single: async (token, owner, spender, value, deadline) => {
		if (permitGenerator.activatePermit) {
			const allowanceData = await permitGenerator.permit2Contract.allowance(owner, token.address, spender);
			const nonce = allowanceData.nonce;
			const { permitData, signature } = permitGenerator._permit2SingleSignature(owner, token.address, value, EXPIRATION, nonce, spender, deadline);
			return { permitType: '2', permitData, signature }
		} else {
			await token.approve(spender, value, {from: owner});
		}
	},
}


module.exports = {
	MAX_UINT_256,
	permitGenerator,
	PERMIT2_ADDRESS,
};
