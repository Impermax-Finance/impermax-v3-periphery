const {
	bnMantissa,
	BN,
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
const DEADLINE = MAX_UINT_256;

function getAmounts(values, A_IS_0) {
	const {
		amountAUser,
		amountBUser,
		amountADesired, 
		amountBDesired, 
		amountAMin, 
		amountBMin
	} = values;
	return {
		amount0User: A_IS_0 ? amountAUser : amountBUser,
		amount1User: A_IS_0 ? amountBUser : amountAUser,
		amount0Desired: A_IS_0 ? amountADesired : amountBDesired,
		amount1Desired: A_IS_0 ? amountBDesired : amountADesired,
		amount0Min: A_IS_0 ? amountAMin : amountBMin,
		amount1Min: A_IS_0 ? amountBMin : amountAMin,	
	};
}

function encodeActions(actions = []) {
	return encode(['tuple(uint256 actionType, bytes actionData, bytes nextAction)[]'], [actions]);
}

async function execute(router, nftlp, borrower, tokenId, actions) {
	const returnValue = await router.execute.call(
		nftlp.address, 
		tokenId,
		DEADLINE,
		actions,
		"0x",
		{from: borrower}
	);
	const receipt = await router.execute(
		nftlp.address, 
		tokenId,
		DEADLINE,
		actions,
		"0x",
		{from: borrower}
	);
	receipt.returnValue = returnValue;
	return receipt;
}

async function mintCollateral(router, nftlp, borrower, tokenId, lpAmount) {
	const actions = encodeActions([
		await router.getMintCollateralAction(lpAmount)
	]);
	
	return execute(router, nftlp, borrower, tokenId, actions);
}

async function mintNewCollateral(router, nftlp, borrower, lpAmount) {
	return mintCollateral(router, nftlp, borrower, MAX_UINT_256, lpAmount);
}

async function redeemCollateral(router, nftlp, borrower, tokenId, percentage) {
	const actions = encodeActions([
		await router.getRedeemCollateralAction(percentage, borrower)
	]);
	
	return execute(router, nftlp, borrower, tokenId, actions);
}

async function borrow(router, nftlp, borrower, tokenId, index, amount) {
	const actions = encodeActions([
		await router.getBorrowAction(index, amount, borrower)
	]);
	
	return execute(router, nftlp, borrower, tokenId, actions);
}

async function repay(router, nftlp, borrower, tokenId, index, amountMax) {
	const actions = encodeActions([
		await router.getRepayUserAction(index, amountMax)
	]);
	
	return execute(router, nftlp, borrower, tokenId, actions);
}


async function leverage(router, nftlp, borrower, tokenId, amountADesired, amountBDesired, amountAMin, amountBMin, permitData0, permitData1, A_IS_0) {
	const t = getAmounts({amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	const permitDataA = A_IS_0 ? permitData0 : permitData1;
	const permitDataB = A_IS_0 ? permitData1 : permitData0;
	
	const actions = encodeActions([
		/*await router.getBorrowAction(0, t.amount0Desired.sub(t.amount0User), router.address),
		await router.getBorrowAction(1, t.amount1Desired.sub(t.amount1User), router.address),
		await router.getAddLiquidityAction(t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min, nftlp.address),
		await router.getMintCollateralAction(0),
		await router.getWithdrawTokenAction(lendingPool.tokens[0], lendingPool.borrowables[0]),
		await router.getWithdrawTokenAction(lendingPool.tokens[1], lendingPool.borrowables[1])*/
		await router.getBorrowAndAddLiquidityAction(0, 0, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min, nftlp.address),
		await router.getMintCollateralAction(0)
	]);
	
	return execute(router, nftlp, borrower, tokenId, actions);
}

async function mintAndLeverage(router, nftlp, borrower, amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin, permitData0, permitData1, A_IS_0) {
	const t = getAmounts({amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	const permitDataA = A_IS_0 ? permitData0 : permitData1;
	const permitDataB = A_IS_0 ? permitData1 : permitData0;
	
	// AMOUNT A DESIREDv è IL TOTALE INCLUSO USERù
	
	const actions = encodeActions([
		/*await router.getBorrowAction(0, t.amount0Desired.sub(t.amount0User), router.address),
		await router.getBorrowAction(1, t.amount1Desired.sub(t.amount1User), router.address),
		await router.getAddLiquidityAction(t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min, nftlp.address),
		await router.getMintCollateralAction(0),
		await router.getWithdrawTokenAction(lendingPool.tokens[0], lendingPool.borrowables[0]),
		await router.getWithdrawTokenAction(lendingPool.tokens[1], lendingPool.borrowables[1])*/
		await router.getBorrowAndAddLiquidityAction(t.amount0User, t.amount1User, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min, nftlp.address),
		await router.getMintCollateralAction(0)
	]);
	
	return execute(router, nftlp, borrower, MAX_UINT_256, actions);
}

async function deleverage(router, nftlp, borrower, tokenId, redeemTokens, amountAMin, amountBMin, permitData, A_IS_0) {
	const totalTokens = await nftlp.liquidity(tokenId);
	if (totalTokens * 1 == 0) console.log("totalTokens 0");
	const percentage = redeemTokens.mul(bnMantissa(1)).div(totalTokens);
	
	// redeem collateral
	// remove liqudity
	// repay 
	// refund
	const t = getAmounts({amountAMin, amountBMin}, A_IS_0);
	
	
	const lendingPool = await router.getLendingPool(nftlp.address);
	const actions = encodeActions([
		await router.getRedeemCollateralAction(percentage, lendingPool.uniswapV2Pair),
		await router.getRemoveLiquidityAction(0, t.amount0Min, t.amount1Min, router.address),
		await router.getRepayRouterAction(0, MAX_UINT_256),
		await router.getRepayRouterAction(1, MAX_UINT_256)
	]);
	
	return execute(router, nftlp, borrower, tokenId, actions);
}

//EIP712

const permitType = {
	PERMIT: 1,
	BORROW_PERMIT: 2,
	NFT_PERMIT: 3,
};

function getDomainSeparator(name, tokenAddress) {
	return keccak256(
		encode(
			['bytes32', 'bytes32', 'bytes32', 'uint256', 'address'],
			[
				keccak256(toUtf8Bytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
				keccak256(toUtf8Bytes(name)),
				keccak256(toUtf8Bytes('1')),
				1,
				tokenAddress
			]
		)
	);
}

const PERMIT_TYPEHASH = keccak256(
	toUtf8Bytes('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
);
const BORROW_PERMIT_TYPEHASH = keccak256(
	toUtf8Bytes('BorrowPermit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
);

async function getApprovalDigest(name, tokenAddress, approve, nonce, deadline, borrowPermit) {
	const DOMAIN_SEPARATOR = getDomainSeparator(name, tokenAddress);
	const TYPEHASH = borrowPermit ? BORROW_PERMIT_TYPEHASH : PERMIT_TYPEHASH;
	return keccak256(
		encodePacked(
			['bytes1', 'bytes1', 'bytes32', 'bytes32'],
			[
				'0x19',
				'0x01',
				DOMAIN_SEPARATOR,
				keccak256(
					encode(
						['bytes32', 'address', 'address', 'uint256', 'uint256', 'uint256'],
						[TYPEHASH, approve.owner, approve.spender, approve.value.toString(), nonce.toString(), deadline.toString()]
					)
				)
			]
		)
	);
}

async function getPermit(opts) {
	const {token, owner, spender, value, deadline, private_key, borrowPermit} = opts;
	const name = await token.name();
	const nonce = await token.nonces(owner);
	const digest = await getApprovalDigest(
		name,
		token.address,
		{owner, spender, value},
		nonce,
		deadline,
		borrowPermit
	);
	const { v, r, s } = ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(private_key, 'hex'));
	return {v, r: hexlify(r), s: hexlify(s)};
}

const permitGenerator = {
	//Note: activatePermit is false by default. If you want to test the permit you need to configure mnemonic with the one of your ganache wallet
	activatePermit: false,
	mnemonic: 'artist rigid narrow swallow catch attend pulp victory drift outside prepare tribe',
	PKs: [],
	initialize: async () => {
		if (!permitGenerator.activatePermit) return;
		const { mnemonicToSeed } = require('bip39');
		const { hdkey } = require('ethereumjs-wallet');
		const seed = await mnemonicToSeed(permitGenerator.mnemonic);
		const hdk = hdkey.fromMasterSeed(seed);
		for (i = 0; i < 10; i++) {
			const borrowerWallet = hdk.derivePath("m/44'/60'/0'/0/"+i).getWallet();
			permitGenerator.PKs[borrowerWallet.getAddressString().toLowerCase()] = borrowerWallet.getPrivateKey();
		}
	},
	_permit: async (token, owner, spender, value, deadline, type) => {
		if (permitGenerator.activatePermit) {
			// TODO this is not setup for nftPermit
			const {v, r, s} = await getPermit({
				token, owner, spender, value, deadline, private_key: permitGenerator.PKs[owner.toLowerCase()], borrowPermit: type == permitType.BORROW_PERMIT
			});
			return encode (
				['bool', 'uint8', 'bytes32', 'bytes32'],
				[value.eq(MAX_UINT_256), v, r, s]
			);
		}
		else {
			if (type == permitType.PERMIT) await token.approve(spender, value, {from: owner});
			if (type == permitType.BORROW_PERMIT) await token.borrowApprove(spender, value, {from: owner});
			if (type == permitType.NFT_PERMIT) await token.approve(spender, value, {from: owner}); // value = tokenId
			return '0x';
		}
	},
	permit: async (token, owner, spender, value, deadline) => {
		return await permitGenerator._permit(token, owner, spender, value, deadline, permitType.PERMIT);
	},
	borrowPermit: async (token, owner, spender, value, deadline) => {
		return await permitGenerator._permit(token, owner, spender, value, deadline, permitType.BORROW_PERMIT);
	},
	nftPermit: async (token, owner, spender, tokenId, deadline) => {
		return await permitGenerator._permit(token, owner, spender, tokenId, deadline, permitType.NFT_PERMIT);
	},
}


module.exports = {
	MAX_UINT_256,
	getAmounts,
	mintCollateral,
	mintNewCollateral,
	redeemCollateral,
	borrow,
	repay,
	leverage,
	mintAndLeverage,
	deleverage,
	getDomainSeparator,
	getApprovalDigest,
	getPermit,
	permitGenerator,
};
