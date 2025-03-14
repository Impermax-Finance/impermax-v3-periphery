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

const Actions = artifacts.require('Actions');
const ImpermaxPermit = artifacts.require('ImpermaxPermit');
const UniswapV3Math = artifacts.require('UniswapV3Math');
const ActionsGetter = artifacts.require('ActionsGetter');
const ImpermaxV3UniV2Router01 = artifacts.require('ImpermaxV3UniV2Router01');
const ImpermaxV3UniV3Router01 = artifacts.require('ImpermaxV3UniV3Router01');
const PoolTokenRouter01 = artifacts.require('PoolTokenRouter01');

const routerManager = {
	initialized: false,
	uniV2: undefined,
	uniV3: undefined,
	poolToken: undefined,
	actionsGetter: undefined,
	initialize: async () => {
		if (routerManager.initialized) return;
		const imperamxPermit = await ImpermaxPermit.new();
		const actions = await Actions.new();
		const uniswapV3Math = await UniswapV3Math.new();
		await PoolTokenRouter01.link(imperamxPermit);
		await ImpermaxV3UniV2Router01.link(imperamxPermit);
		await ImpermaxV3UniV2Router01.link(actions);
		await ImpermaxV3UniV3Router01.link(imperamxPermit);
		await ImpermaxV3UniV3Router01.link(actions);
		await ImpermaxV3UniV3Router01.link(uniswapV3Math);
		await ActionsGetter.link(actions);
		routerManager.actionsGetter = await ActionsGetter.new();
	},
	initializePoolToken: async (wethAddress) => {
		routerManager.poolToken = await PoolTokenRouter01.new(wethAddress);
	},
	initializeUniV2: async (impermaxFactoryAddress, wethAddress) => {
		routerManager.uniV2 = await ImpermaxV3UniV2Router01.new(impermaxFactoryAddress, wethAddress);
	},
	initializeUniV3: async (impermaxFactoryAddress, uniswapV3FactoryAddress, wethAddress) => {
		routerManager.uniV3 = await ImpermaxV3UniV3Router01.new(impermaxFactoryAddress, uniswapV3FactoryAddress, wethAddress);
	},
}

//UTILITIES

const MAX_UINT_256 = (new BN(2)).pow(new BN(256)).sub(new BN(1));

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
function encodePermits(permits = []) {
	if (!permits[0] || !permits[0].signature) permits = [];
	//console.log("permits", permits)
	return encode(['tuple(uint256 permitType, bytes permitData, bytes signature)[]'], [permits]);
}

async function execute(router, nftlp, from, tokenId, actions, permits, withCollateralTransfer, value = 0) {
	const receipt = await router.execute(
		nftlp.address, 
		tokenId,
		encodeActions(actions),
		encodePermits(permits),
		withCollateralTransfer,
		{from, value}
	);
	receipt.tokenId = tokenId;
	const lendingPool = await router.getLendingPool(nftlp.address);
	const eventSignature = keccak256(toUtf8Bytes("Transfer(address,address,uint256)"));
	for (const rawLog of receipt.receipt.rawLogs) {
		if (rawLog.topics[0] != eventSignature) continue;
		if (rawLog.address.toLowerCase() != lendingPool.collateral.toLowerCase()) continue;
		if (rawLog.topics[1] != '0x0000000000000000000000000000000000000000000000000000000000000000') continue;
		if (rawLog.topics[2].slice(26) != router.address.slice(2).toLowerCase()) continue;
		receipt.tokenId = new BN(Number(rawLog.topics[3].toString()));
	}
	return receipt;
}

async function mintCollateral(router, nftlp, borrower, tokenId, lpAmount, permits, amountADesired = 0, amountBDesired = 0, amountAMin = 0, amountBMin = 0, A_IS_0 = true) {
	const t = getAmounts({amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	console.log(await routerManager.actionsGetter.getMintUniV2EmptyAction());
	const actions = [
		await routerManager.actionsGetter.getMintUniV2Action(lpAmount, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min)
	];
	if (tokenId*1==MAX_UINT_256*1) actions.unshift(await routerManager.actionsGetter.getMintUniV2EmptyAction());
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false);
}

async function mintCollateralETH(router, nftlp, borrower, tokenId, lpAmount, permits, amountADesired, amountBDesired, amountAMin, amountBMin, A_IS_0, ETH_IS_0) {
	const t = getAmounts({amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	let amountETH = ETH_IS_0 ? t.amount0Desired : t.amount1Desired;
	const actions = [
		await routerManager.actionsGetter.getMintUniV2Action(lpAmount, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)
	];
	if (tokenId*1==MAX_UINT_256*1) actions.unshift(await routerManager.actionsGetter.getMintUniV2EmptyAction());
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false, amountETH);
}

async function mintNewCollateral(router, nftlp, borrower, lpAmount, permits) {
	return mintCollateral(router, nftlp, borrower, MAX_UINT_256, lpAmount, permits);
}

async function redeemCollateral(router, nftlp, borrower, tokenId, percentage, permits) {
	const actions = [
		await routerManager.actionsGetter.getRedeemUniV2Action(percentage, 0, 0, borrower)
	];
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false);
}

async function redeemCollateralETH(router, nftlp, borrower, tokenId, percentage, ETH_IS_0, permits) {
	const lendingPool = await router.getLendingPool(nftlp.address);
	const tokenToWithdraw = ETH_IS_0 ? lendingPool.tokens[1] : lendingPool.tokens[0];
	const actions = [
		await routerManager.actionsGetter.getRedeemUniV2Action(percentage, 0, 0, router.address),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower),
		await routerManager.actionsGetter.getWithdrawTokenAction(tokenToWithdraw, borrower)
	];
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false);
}

async function borrowETH(router, nftlp, borrower, tokenId, index, amount, permits) {
	const actions = [
		await routerManager.actionsGetter.getBorrowAction(index, amount, router.address),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)
	];
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, true);
}

async function borrow(router, nftlp, borrower, tokenId, index, amount, permits) {
	const actions = [
		await routerManager.actionsGetter.getBorrowAction(index, amount, borrower)
	];
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, true);
}

async function repay(router, nftlp, borrower, tokenId, index, amountMax, permits) {
	const actions = [
		await routerManager.actionsGetter.getRepayUserAction(index, amountMax)
	];
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false);
}

async function repayETH(router, nftlp, borrower, tokenId, index, amountMax, permits) {
	const actions = [
		await routerManager.actionsGetter.getRepayRouterAction(index, amountMax, router.address),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)	
	];
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false, amountMax);
}


async function leverage(router, nftlp, borrower, tokenId, amountADesired, amountBDesired, amountAMin, amountBMin, A_IS_0, permits) {
	const t = getAmounts({amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	
	const actions = [
		await routerManager.actionsGetter.getBorrowAndMintUniV2Action(0, 0, 0, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min),
	];
	if (tokenId*1==MAX_UINT_256*1) actions.unshift(await routerManager.actionsGetter.getMintUniV2EmptyAction());
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, true);
}

async function mintAndLeverage(router, nftlp, borrower, amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin, A_IS_0, permits) {
	const t = getAmounts({amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
		
	const actions = [
		await routerManager.actionsGetter.getMintUniV2EmptyAction(),
		await routerManager.actionsGetter.getBorrowAndMintUniV2Action(0, t.amount0User, t.amount1User, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min),
	];
	
	return execute(router, nftlp, borrower, MAX_UINT_256, actions, permits, true);
}

async function mintAndLeverageETH(router, nftlp, borrower, amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin, A_IS_0, ETH_IS_0, permits) {
	const t = getAmounts({amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	
	let amountETH = ETH_IS_0 ? t.amount0User : t.amount1User;
	
	const actions = [
		await routerManager.actionsGetter.getMintUniV2EmptyAction(),
		await routerManager.actionsGetter.getBorrowAndMintUniV2Action(0, t.amount0User, t.amount1User, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)	// refund only needed if we're not borrowing ETH
	];
	
	return execute(router, nftlp, borrower, MAX_UINT_256, actions, permits, true, amountETH);
}

async function deleverage(router, nftlp, borrower, tokenId, redeemTokens, amountAMin, amountBMin, A_IS_0, permits) {
	const totalTokens = await nftlp.liquidity(tokenId);
	if (totalTokens * 1 == 0) console.log("totalTokens 0");
	const percentage = redeemTokens.mul(bnMantissa(1)).div(totalTokens);
	
	// redeem collateral
	// remove liqudity
	// repay 
	// refund
	const t = getAmounts({amountAMin, amountBMin}, A_IS_0);
	
	
	const lendingPool = await router.getLendingPool(nftlp.address);
	const WETH = await router.WETH();
	const ETH_IS_0 = WETH == lendingPool.tokens[0];
	const ETH_IS_1 = WETH == lendingPool.tokens[1];
	const actions = [
		await routerManager.actionsGetter.getRedeemUniV2Action(percentage, t.amount0Min, t.amount1Min, router.address),
		await routerManager.actionsGetter.getRepayRouterAction(0, MAX_UINT_256, ETH_IS_0 ? router.address : borrower),
		await routerManager.actionsGetter.getRepayRouterAction(1, MAX_UINT_256, ETH_IS_1 ? router.address : borrower)
	];
	if (ETH_IS_0 || ETH_IS_1) {
		actions.push(
			await routerManager.actionsGetter.getWithdrawEthAction(borrower)	
		);
	}
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false);
}

// UNI V3 ACTIONS

async function mintCollateralETHUniV3(router, nftlp, borrower, tokenId, fee, tickLower, tickUpper, amountADesired, amountBDesired, amountAMin, amountBMin, A_IS_0, ETH_IS_0, permits) {
	const t = getAmounts({amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	let amountETH = ETH_IS_0 ? t.amount0Desired : t.amount1Desired;
	const actions = [
		await routerManager.actionsGetter.getMintUniV3Action(t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)
	];
	if (tokenId*1==MAX_UINT_256*1) actions.unshift(await routerManager.actionsGetter.getMintUniV3EmptyAction(fee, tickLower, tickUpper));
	
	return execute(router, nftlp, borrower, tokenId, actions, permits, false, amountETH);
}

async function getMintCollateralETHUniV3Action(router, borrower, tokenId, fee, tickLower, tickUpper, amountADesired, amountBDesired, amountAMin, amountBMin, A_IS_0, ETH_IS_0) {
	const t = getAmounts({amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	
	const actions = [
		await routerManager.actionsGetter.getMintUniV3Action(t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)
	];
	if (tokenId*1==MAX_UINT_256*1) actions.unshift(await routerManager.actionsGetter.getMintUniV3EmptyAction(fee, tickLower, tickUpper));
	
	return encodeActions(actions);
}

async function getMintAndLeverageETHUniV3Action(router, borrower, tokenId, fee, tickLower, tickUpper, amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin, A_IS_0, ETH_IS_0) {
	const t = getAmounts({amountAUser, amountBUser, amountADesired, amountBDesired, amountAMin, amountBMin}, A_IS_0);
	
	const actions = [
		await routerManager.actionsGetter.getBorrowAndMintUniV3Action(t.amount0User, t.amount1User, t.amount0Desired, t.amount1Desired, t.amount0Min, t.amount1Min),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)	// refund only needed if we're not borrowing ETH
	];
	if (tokenId*1==MAX_UINT_256*1) actions.unshift(await routerManager.actionsGetter.getMintUniV3EmptyAction(fee, tickLower, tickUpper));
	
	return encodeActions(actions);
}

async function getDeleverageETHUniV3Action(router, routerAddress, borrower, percentage, amountAMin, amountBMin, A_IS_0, ETH_IS_0) {	
	// redeem collateral
	// remove liqudity
	// repay 
	// refund
	const t = getAmounts({amountAMin, amountBMin}, A_IS_0);
	const actions = [
		await routerManager.actionsGetter.getRedeemUniV3Action(percentage, t.amount0Min, t.amount1Min, routerAddress),
		await routerManager.actionsGetter.getRepayRouterAction(0, MAX_UINT_256, ETH_IS_0 ? routerAddress : borrower),
		await routerManager.actionsGetter.getRepayRouterAction(1, MAX_UINT_256, !ETH_IS_0 ? routerAddress : borrower),
		await routerManager.actionsGetter.getWithdrawEthAction(borrower)
	];
	
	return encodeActions(actions);
}


module.exports = {
	routerManager,
	MAX_UINT_256,
	getAmounts,
	encodePermits,
	mintCollateral,
	mintCollateralETH,
	mintNewCollateral,
	redeemCollateral,
	redeemCollateralETH,
	borrow,
	borrowETH,
	repay,
	repayETH,
	leverage,
	mintAndLeverage,
	mintAndLeverageETH,
	deleverage,
	mintCollateralETHUniV3,
	getMintCollateralETHUniV3Action,
	getMintAndLeverageETHUniV3Action,
	getDeleverageETHUniV3Action,
};
