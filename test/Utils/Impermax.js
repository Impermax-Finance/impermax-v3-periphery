"use strict";

const { 
	dfn,
	bnMantissa,
	BN,
	expectEqual,
} = require('./JS');
const {
	encodeParameters,
	etherBalance,
	etherUnsigned,
	address,
	encode,
	encodePacked,
} = require('./Ethereum');
const { hexlify, keccak256, toUtf8Bytes } = require('ethers/utils');
const { ecsign } = require('ethereumjs-util');

const MockERC20 = artifacts.require('MockERC20');
const MockUniswapV2Factory = artifacts.require('MockUniswapV2Factory');
const MockUniswapV2Pair = artifacts.require('MockUniswapV2Pair');
const MockUniswapV3Factory = artifacts.require('MockUniswapV3Factory');
const MockUniswapV3Pair = artifacts.require('MockUniswapV3Pair');
const MockOracle = artifacts.require('MockOracle');
const TokenizedUniswapV2Factory = artifacts.require('TokenizedUniswapV2Factory');
const TokenizedUniswapV2Position = artifacts.require('TokenizedUniswapV2Position');
const TokenizedUniswapV3Factory = artifacts.require('TokenizedUniswapV3Factory');
const TokenizedUniswapV3Position = artifacts.require('TokenizedUniswapV3Position');
const MockTokenizedCLPosition = artifacts.require('MockTokenizedCLPosition');
const BDeployer = artifacts.require('BDeployer');
const CDeployer = artifacts.require('CDeployer');
const Factory = artifacts.require('ImpermaxV3Factory');
const ImpermaxERC20 = artifacts.require('ImpermaxERC20Harness');
const ImpermaxERC721 = artifacts.require('ImpermaxERC721Harness');
const PoolToken = artifacts.require('PoolTokenHarness');
const CollateralProduction = artifacts.require('ImpermaxV3Collateral');
const BorrowableProduction = artifacts.require('ImpermaxV3Borrowable');
const Collateral = artifacts.require('CollateralHarness');
const Borrowable = artifacts.require('BorrowableHarness');
const BAllowance = artifacts.require('BAllowanceHarness');
const BInterestRateModel = artifacts.require('BInterestRateModelHarness');
const ImpermaxCallee = artifacts.require('ImpermaxCallee');
const ReentrantCallee = artifacts.require('ReentrantCallee');
const Recipient = artifacts.require('Recipient');
const MockBorrowTracker = artifacts.require('MockBorrowTracker');
const Liquidator = artifacts.require('Liquidator');

//MOCK EXTERNAL DEPLOYER

async function makeErc20Token(opts = {}) {
	const quantity = etherUnsigned(dfn(opts.quantity, 1e25));
	const decimals = etherUnsigned(dfn(opts.decimals, 18));
	const symbol = opts.symbol || 'DAI';
	const name = opts.name || `Erc20 ${symbol}`;
	return await ImpermaxERC20.new(name, symbol);
}

async function makeUniswapV2Factory(opts = {}) {
	return await MockUniswapV2Factory.new();
}

async function makeUniswapV2Pair(opts = {}) {
	const token0 = opts.token0 || await makeErc20Token(opts.t0);
	const token1 = opts.token1 || await makeErc20Token(opts.t1);
	const uniswapV2Pair = await MockUniswapV2Pair.new(token0.address, token1.address);
	if (opts.withFactory) {
		const uniswapV2Factory = opts.uniswapV2Factory || await makeUniswapV2Factory(opts);
		await uniswapV2Factory.addPair(token0.address, token1.address, uniswapV2Pair.address);
		return Object.assign(uniswapV2Pair, {obj: {token0, token1, uniswapV2Factory}}); 
	}
	else {
		return Object.assign(uniswapV2Pair, {obj: {token0, token1}});
	}
}

async function makeUniswapV3Factory(opts = {}) {
	return await MockUniswapV3Factory.new();
}

async function makeUniswapV3Pair(opts = {}) {
	const token0 = opts.token0 || await makeErc20Token(opts.t0);
	const token1 = opts.token1 || await makeErc20Token(opts.t1);
	const fee = opts.fee || 3000;
	const uniswapV3Pair = await MockUniswapV3Pair.new(token0.address, token1.address);
	if (opts.withFactory) {
		const uniswapV3Factory = opts.uniswapV3Factory || await makeUniswapV3Factory(opts);
		await uniswapV3Factory.addPool(token0.address, token1.address, fee, uniswapV3Pair.address);
		return Object.assign(uniswapV3Pair, {obj: {token0, token1, uniswapV3Factory}}); 
	}
	return Object.assign(uniswapV3Pair, {obj: {token0, token1}});
}

async function makeSimpleUniswapOracle(opts = {}) {
	return await MockOracle.new();
}

async function makeTokenizedUniswapV2Factory(opts = {}) {
	const simpleUniswapOracle = opts.simpleUniswapOracle || await makeSimpleUniswapOracle(opts);
	const tokenizedUniswapV2Factory = await TokenizedUniswapV2Factory.new(simpleUniswapOracle.address);
	return Object.assign(tokenizedUniswapV2Factory, {obj: {simpleUniswapOracle}});
}

async function makeTokenizedUniswapV2Position(opts = {}) {
	const uniswapV2Pair = opts.uniswapV2Pair || await makeUniswapV2Pair({
		t0: opts.t0, token0: opts.token0,
		t1: opts.t1, token1: opts.token1,
	});
	const tokenizedUniswapV2Factory = opts.factory || await makeTokenizedUniswapV2Factory(opts);
	const address = await tokenizedUniswapV2Factory.createNFTLP.call(uniswapV2Pair.address);
	await tokenizedUniswapV2Factory.createNFTLP(uniswapV2Pair.address);
	return Object.assign(await TokenizedUniswapV2Position.at(address), {obj: {uniswapV2Pair, tokenizedUniswapV2Factory}});
}

async function makeTokenizedUniswapV3Factory(opts = {}) {
	const uniswapV3Factory = opts.uniswapV3Factory || await makeUniswapV3Factory(opts);;
	const tokenizedUniswapV3Factory = await TokenizedUniswapV3Factory.new(uniswapV3Factory.address);
	return Object.assign(tokenizedUniswapV3Factory, {obj: {uniswapV3Factory}});
}

async function makeTokenizedUniswapV3Position(opts = {}) {
	const tokenizedUniswapV3Factory = await makeTokenizedUniswapV3Factory(opts);
	const uniswapV3Pair = opts.uniswapV3Pair || await makeUniswapV3Pair({
		t0: opts.t0, token0: opts.token0,
		t1: opts.t1, token1: opts.token1,
		withFactory: true,
		uniswapV3Factory: tokenizedUniswapV3Factory.obj.uniswapV3Factory,
	});
	const address = await tokenizedUniswapV3Factory.createNFTLP.call(uniswapV3Pair.obj.token0.address, uniswapV3Pair.obj.token1.address);
	await tokenizedUniswapV3Factory.createNFTLP(uniswapV3Pair.obj.token0.address, uniswapV3Pair.obj.token1.address);
	return Object.assign(await TokenizedUniswapV3Position.at(address), {obj: {uniswapV3Pair, tokenizedUniswapV3Factory}});
}

/*
async function makeTokenizedUniswapV2Position(opts = {}) {
	const uniswapV2Pair = opts.uniswapV2Pair || await makeUniswapV2Pair({
		t0: opts.t0, token0: opts.token0,
		t1: opts.t1, token1: opts.token1,
	});
	const tokenizedUniswapV2Position = await TokenizedUniswapV2Position.new();
	const simpleUniswapOracle = opts.simpleUniswapOracle || await makeSimpleUniswapOracle(opts);
	await tokenizedUniswapV2Position._initialize(
		uniswapV2Pair.address,
		uniswapV2Pair.obj.token0.address,
		uniswapV2Pair.obj.token1.address,
		simpleUniswapOracle.address
	)
	return Object.assign(tokenizedUniswapV2Position, {obj: {uniswapV2Pair, simpleUniswapOracle}});
}

async function makeTokenizedUniswapV3Position(opts = {}) {
	const uniswapV3Pair = opts.uniswapV3Pair || await makeUniswapV3Pair({
		t0: opts.t0, token0: opts.token0,
		t1: opts.t1, token1: opts.token1,
		withFactory: true,
	});
	const tokenizedUniswapV3Position = await TokenizedUniswapV3Position.new();
	await tokenizedUniswapV3Position._initialize(
		uniswapV3Pair.obj.uniswapV3Factory.address,
		uniswapV3Pair.obj.token0.address,
		uniswapV3Pair.obj.token1.address,
	)
	return Object.assign(tokenizedUniswapV3Position, {obj: {uniswapV3Pair}});
}
*/
async function makeTokenizedCLPosition(opts = {}) {
	const token0 = opts.token0 || await makeErc20Token(opts.t0);
	const token1 = opts.token1 || await makeErc20Token(opts.t1);
	const tokenizedCLPosition = await MockTokenizedCLPosition.new(token0.address, token1.address);
	return Object.assign(tokenizedCLPosition, {obj: {token0, token1}});
	/*if (opts.withFactory) {
		const tokenizedCLPosition = opts.uniswapV2Factory || await makeUniswapV2Factory(opts);
		await tokenizedCLPosition.addPair(token0.address, token1.address, uniswapV2Pair.address);
		return Object.assign(tokenizedCLPosition, {obj: {token0, token1, uniswapV2Factory}}); 
	}
	else {
		return Object.assign(uniswapV2Pair, {obj: {token0, token1}});
	}*/
}

//IMPERMAX DEPLOYER

async function makeBDeployer(opts = {}) {
	return await BDeployer.new();
}

async function makeCDeployer(opts = {}) {
	return await CDeployer.new();
}


async function makeFactory(opts = {}) {
	const admin = opts.admin || address(0);
	const reservesAdmin = opts.reservesAdmin || address(0);
	const bDeployer = opts.bDeployer || await makeBDeployer(opts);
	const cDeployer = opts.cDeployer || await makeCDeployer(opts);
	const uniswapV2Factory = opts.uniswapV2Factory || await makeUniswapV2Factory(opts);
	const factory = await Factory.new(admin, reservesAdmin, bDeployer.address, cDeployer.address);
	return Object.assign(factory, {obj: {admin, reservesAdmin, bDeployer, cDeployer, uniswapV2Factory,
		checkLendingPool: async (pair, {initialized, lendingPoolId, collateral, borrowable0, borrowable1}) => {
			const lendingPool = await factory.getLendingPool(pair.address);
			if(initialized) expect(lendingPool.initialized).to.eq(initialized);
			if(lendingPoolId) expectEqual(lendingPool.lendingPoolId, lendingPoolId);
			if(collateral) expect(lendingPool.collateral).to.eq(collateral);
			if(borrowable0) expect(lendingPool.borrowable0).to.eq(borrowable0);
			if(borrowable1) expect(lendingPool.borrowable1).to.eq(borrowable1);
		},
	}});
}

async function makePoolToken(opts = {}) {
	const underlying = opts.underlying || await makeErc20Token(opts.underlyingOpts);
	const poolToken = await PoolToken.new();
	poolToken.setUnderlying(underlying.address);
	return Object.assign(poolToken, {obj: {underlying}});	
}

async function makeLendingPool(opts = {}) {
	const factory = opts.factory || await makeFactory(opts);
	const tokenizedCLPosition = opts.tokenizedCLPosition || await makeTokenizedCLPosition({
		t0: opts.t0, token0: opts.token0,
		t1: opts.t1, token1: opts.token1,
	});
	const collateralAddr = await factory.createCollateral.call(tokenizedCLPosition.address);
	const borrowable0Addr = await factory.createBorrowable0.call(tokenizedCLPosition.address);
	const borrowable1Addr = await factory.createBorrowable1.call(tokenizedCLPosition.address);
	await factory.createCollateral(tokenizedCLPosition.address);
	await factory.createBorrowable0(tokenizedCLPosition.address);
	await factory.createBorrowable1(tokenizedCLPosition.address);
	const collateral = await CollateralProduction.at(collateralAddr);
	const borrowable0 = await BorrowableProduction.at(borrowable0Addr);
	const borrowable1 = await BorrowableProduction.at(borrowable1Addr);
	await factory.initializeLendingPool(tokenizedCLPosition.address);
	return { factory, tokenizedCLPosition, collateral, borrowable0, borrowable1 };
}

//EIP712

function getDomainSeparator(name, tokenAddress) {
	return keccak256(
		encode(
			['bytes32', 'bytes32', 'bytes32', 'uint256', 'address'],
			[
				keccak256(toUtf8Bytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
				keccak256(toUtf8Bytes(name)),
				keccak256(toUtf8Bytes('1')),
				1337, // ganache chain id
				tokenAddress
			]
		)
	);
}

async function getApprovalDigest(name, tokenAddress, approve, nonce, deadline) {
	const DOMAIN_SEPARATOR = getDomainSeparator(name, tokenAddress);
	const PERMIT_TYPEHASH = keccak256(
		toUtf8Bytes('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
	);
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
						[PERMIT_TYPEHASH, approve.owner, approve.spender, approve.value.toString(), nonce.toString(), deadline.toString()]
					)
				)
			]
		)
	);
}

async function getBorrowApprovalDigest(name, tokenAddress, approve, nonce, deadline) {
	const DOMAIN_SEPARATOR = getDomainSeparator(name, tokenAddress);
	const BORROW_PERMIT_TYPEHASH = keccak256(
		toUtf8Bytes('BorrowPermit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
	);
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
						[BORROW_PERMIT_TYPEHASH, approve.owner, approve.spender, approve.value.toString(), nonce.toString(), deadline.toString()]
					)
				)
			]
		)
	);
}

async function getNftApprovalDigest(name, tokenAddress, approve, nonce, deadline) {
	const DOMAIN_SEPARATOR = getDomainSeparator(name, tokenAddress);
	const PERMIT_TYPEHASH = keccak256(
		toUtf8Bytes('Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)')
	);
	return keccak256(
		encodePacked(
			['bytes1', 'bytes1', 'bytes32', 'bytes32'],
			[
				'0x19',
				'0x01',
				DOMAIN_SEPARATOR,
				keccak256(
					encode(
						['bytes32', 'address', 'uint256', 'uint256', 'uint256'],
						[PERMIT_TYPEHASH, approve.spender, approve.tokenId.toString(), nonce.toString(), deadline.toString()]
					)
				)
			]
		)
	);
}

async function sendPermit(opts) {
	const {token, owner, spender, value, deadline, private_key} = opts;
	const name = await token.name();
	const nonce = await token.nonces(owner);
	const digest = await getApprovalDigest(
		name,
		token.address,
		{owner, spender, value},
		nonce,
		deadline
	);
	const { v, r, s } = ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(private_key, 'hex'));
	return token.permit(owner, spender, value, deadline, v, hexlify(r), hexlify(s));
}

async function sendBorrowPermit(opts) {
	const {token, owner, spender, value, deadline, private_key} = opts;
	const name = await token.name();
	const nonce = await token.nonces(owner);
	const digest = await getBorrowApprovalDigest(
		name,
		token.address,
		{owner, spender, value},
		nonce,
		deadline
	);
	const { v, r, s } = ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(private_key, 'hex'));
	return token.borrowPermit(owner, spender, value, deadline, v, hexlify(r), hexlify(s));
}

async function sendNftPermit(opts) {
	const {token, spender, tokenId, deadline, private_key} = opts;
	const name = await token.name();
	const nonce = await token.nonces(tokenId);
	const digest = await getNftApprovalDigest(
		name,
		token.address,
		{spender, tokenId},
		nonce,
		deadline
	);
	const { v, r, s } = ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(private_key, 'hex'));
	return token.permit(spender, tokenId, deadline, v, hexlify(r), hexlify(s));
}


module.exports = {
	MockERC20,
	MockTokenizedCLPosition,
	BDeployer,
	CDeployer,
	Factory,
	ImpermaxERC20,
	ImpermaxERC721,
	PoolToken,
	CollateralProduction,
	BorrowableProduction,
	Collateral,
	Borrowable,
	BAllowance,
	BInterestRateModel,
	ImpermaxCallee,
	ReentrantCallee,
	Recipient,
	MockBorrowTracker,
	Liquidator,
	
	makeErc20Token,
	makeUniswapV2Factory,
	makeUniswapV2Pair,
	makeUniswapV3Factory,
	makeUniswapV3Pair,
	makeSimpleUniswapOracle,
	makeTokenizedUniswapV2Position,
	makeTokenizedUniswapV3Position,
	makeTokenizedCLPosition,
	//makeBDeployer,
	//makeCDeployer,
	makeFactory,
	makePoolToken,
	makeLendingPool,
	
	getDomainSeparator,
	getApprovalDigest,
	getBorrowApprovalDigest,
	getNftApprovalDigest,
	sendPermit,
	sendBorrowPermit,
	sendNftPermit,
};
