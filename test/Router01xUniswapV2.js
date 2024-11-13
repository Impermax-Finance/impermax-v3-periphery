const {
	expectEqual,
	expectEvent,
	expectRevert,
	expectAlmostEqualMantissa,
	bnMantissa,
	BN,
} = require('./Utils/JS');
const {
	address,
	increaseTime,
	encode,
} = require('./Utils/Ethereum');
const {
	getAmounts,
	mintCollateral,
	mintCollateralETH,
	mintNewCollateral,
	redeemCollateral,
	redeemCollateralETH,
	repay,
	repayETH,
	borrow,
	borrowETH,
	leverage,
	deleverage,
	permitGenerator,
} = require('./Utils/ImpermaxPeriphery');
const { keccak256, toUtf8Bytes } = require('ethers/utils');

const MAX_UINT_256 = (new BN(2)).pow(new BN(256)).sub(new BN(1));
const DEADLINE = MAX_UINT_256;

const MockERC20 = artifacts.require('MockERC20');
const UniswapV2Factory = artifacts.require('UniswapV2Factory');
const UniswapV2Pair = artifacts.require('UniswapV2Pair');
const SimpleUniswapOracle = artifacts.require('SimpleUniswapOracle');
const Factory = artifacts.require('ImpermaxV3Factory');
const BDeployer = artifacts.require('BDeployer');
const CDeployer = artifacts.require('CDeployer');
const Collateral = artifacts.require('ImpermaxV3Collateral');
const Borrowable = artifacts.require('ImpermaxV3Borrowable');
const ImpermaxV3UniV2Router01 = artifacts.require('ImpermaxV3UniV2Router01');
const ImpermaxV3LendRouter01 = artifacts.require('ImpermaxV3LendRouter01');
const TokenizedUniswapV2Factory = artifacts.require('TokenizedUniswapV2Factory');
const TokenizedUniswapV2Position = artifacts.require('TokenizedUniswapV2Position');
const WETH9 = artifacts.require('WETH9');

const oneMantissa = (new BN(10)).pow(new BN(18));
const UNI_LP_AMOUNT = oneMantissa.mul(new BN(100));
const ETH_LP_AMOUNT = oneMantissa;
const UNI_LEND_AMOUNT = oneMantissa.mul(new BN(1000));
const ETH_LEND_AMOUNT = oneMantissa.mul(new BN(15));
const UNI_BORROW_AMOUNT = UNI_LP_AMOUNT.div(new BN(2));
const ETH_BORROW_AMOUNT = ETH_LP_AMOUNT.div(new BN(2));
const UNI_REPAY_AMOUNT1 = UNI_BORROW_AMOUNT.div(new BN(2));
const ETH_REPAY_AMOUNT1 = ETH_BORROW_AMOUNT.div(new BN(2));
const UNI_REPAY_AMOUNT2 = UNI_BORROW_AMOUNT;
const ETH_REPAY_AMOUNT2 = ETH_BORROW_AMOUNT;
// with default settings the max leverage is 7.61x
const UNI_LEVERAGE_AMOUNT_HIGH = oneMantissa.mul(new BN(700));
const ETH_LEVERAGE_AMOUNT_HIGH = oneMantissa.mul(new BN(7));
const UNI_LEVERAGE_AMOUNT = oneMantissa.mul(new BN(610));
const ETH_LEVERAGE_AMOUNT = oneMantissa.mul(new BN(6));
const EXPECTED_UNI_LEVERAGE_AMOUNT = oneMantissa.mul(new BN(600));
const LEVERAGE = new BN(7);
// enough price change cause to be liquidatable
const UNI_BUY = oneMantissa.mul(new BN(1200)).div(new BN(10));
const ETH_BOUGHT = oneMantissa.mul(new BN(10)).div(new BN(10));
const UNI_LIQUIDATE_AMOUNT = oneMantissa.mul(new BN(10));
const ETH_LIQUIDATE_AMOUNT = oneMantissa.mul(new BN(1));
const UNI_LIQUIDATE_AMOUNT2 = oneMantissa.mul(new BN(1000));
const ETH_LIQUIDATE_AMOUNT2 = oneMantissa.mul(new BN(100));
const MAX_APPROVE_ETH_AMOUNT = oneMantissa.mul(new BN(6));

let TOKEN_ID;
let ETH_IS_0;
const INITIAL_EXCHANGE_RATE = oneMantissa;
const MINIMUM_LIQUIDITY = new BN(1000);

async function checkETHBalance(operation, user, expectedChange, negative = false) {
	const balancePrior = await web3.eth.getBalance(user)
	const receipt = await operation;
	const balanceAfter = await web3.eth.getBalance(user);
	const gasUsed = receipt.receipt.gasUsed * 1e9;
	//console.log("balancePrior", balancePrior / 1e18 - 980);
	//console.log("balanceAfter", balanceAfter / 1e18 - 980);
	//console.log("gasUsed", gasUsed / 1e18);
	//console.log("expectedChange", expectedChange / 1e18);
	if (negative) {
		const balanceDiff = bnMantissa((balancePrior*1 - balanceAfter*1) / 1e18);
		const expected = bnMantissa((expectedChange*1 + gasUsed*1) / 1e18);
		expectAlmostEqualMantissa(balanceDiff, expected);
	} else {
		const balanceDiff = bnMantissa((balanceAfter*1 - balancePrior*1) / 1e18);
		const expected = bnMantissa((expectedChange*1 - gasUsed*1) / 1e18);
		expectAlmostEqualMantissa(balanceDiff, expected);
	}
}

contract('ImpermaxV3UniV2Router01', function (accounts) {
	let root = accounts[0];
	let borrower = accounts[1];
	let lender = accounts[2];
	let liquidator = accounts[3];
	
	let uniswapV2Factory;
	let tokenizedUniswapV2PositionFactory;
	let simpleUniswapOracle;
	let impermaxFactory;
	let WETH;
	let UNI;
	let uniswapV2Pair;
	let nftlp;
	let collateral;
	let borrowableWETH;
	let borrowableUNI;
	let router;
	let routerLend;
	
	before(async () => {
		uniswapV2Factory = await UniswapV2Factory.new(address(0));
		simpleUniswapOracle = await SimpleUniswapOracle.new();
		tokenizedUniswapV2Factory = await TokenizedUniswapV2Factory.new(simpleUniswapOracle.address);
		const bDeployer = await BDeployer.new();
		const cDeployer = await CDeployer.new();
		impermaxFactory = await Factory.new(address(0), address(0), bDeployer.address, cDeployer.address);
		WETH = await WETH9.new();
		UNI = await MockERC20.new('Uniswap', 'UNI');
		const uniswapV2PairAddress = await uniswapV2Factory.createPair.call(WETH.address, UNI.address);
		await uniswapV2Factory.createPair(WETH.address, UNI.address);
		uniswapV2Pair = await UniswapV2Pair.at(uniswapV2PairAddress);
		const nftlpAddress = await tokenizedUniswapV2Factory.createNFTLP.call(uniswapV2PairAddress);
		await tokenizedUniswapV2Factory.createNFTLP(uniswapV2PairAddress);
		nftlp = await TokenizedUniswapV2Position.at(nftlpAddress);
		await UNI.mint(borrower, UNI_LP_AMOUNT);
		await UNI.mint(lender, UNI_LEND_AMOUNT);
		await WETH.deposit({value: ETH_LP_AMOUNT, from: borrower});
		await UNI.transfer(uniswapV2PairAddress, UNI_LP_AMOUNT, {from: borrower});
		await WETH.transfer(uniswapV2PairAddress, ETH_LP_AMOUNT, {from: borrower});
		await uniswapV2Pair.mint(borrower);
		LP_AMOUNT = await uniswapV2Pair.balanceOf(borrower);
		await simpleUniswapOracle.initialize(uniswapV2PairAddress);
		collateralAddress = await impermaxFactory.createCollateral.call(nftlpAddress);
		borrowable0Address = await impermaxFactory.createBorrowable0.call(nftlpAddress);
		borrowable1Address = await impermaxFactory.createBorrowable1.call(nftlpAddress);
		await impermaxFactory.createCollateral(nftlpAddress);
		await impermaxFactory.createBorrowable0(nftlpAddress);
		await impermaxFactory.createBorrowable1(nftlpAddress);
		await impermaxFactory.initializeLendingPool(nftlpAddress);
		collateral = await Collateral.at(collateralAddress);
		const borrowable0 = await Borrowable.at(borrowable0Address);
		const borrowable1 = await Borrowable.at(borrowable1Address);
		ETH_IS_0 = await borrowable0.underlying() == WETH.address;
		if (ETH_IS_0) [borrowableWETH, borrowableUNI] = [borrowable0, borrowable1];
		else [borrowableWETH, borrowableUNI] = [borrowable1, borrowable0]
		router = await ImpermaxV3UniV2Router01.new(impermaxFactory.address, WETH.address);
		routerLend = await ImpermaxV3LendRouter01.new(impermaxFactory.address, WETH.address);
		await increaseTime(3700); // wait for oracle to be ready
		await permitGenerator.initialize();
	});
	
	// TODO REPEAT TEST TO TEST CHECKOWNERNFT

	it('optimal liquidity', async () => {
		const t1 = getAmounts({
			amountADesired: '8', 
			amountBDesired: '1000', 
			amountAMin: '0', 
			amountBMin: '600'
		}, ETH_IS_0);
		const r1 = await router._optimalLiquidityUniV2(uniswapV2Pair.address, t1.amount0Desired, t1.amount1Desired, t1.amount0Min, t1.amount1Min);
		expect(r1.amount0 * 1).to.eq(ETH_IS_0 ? 8 : 800);
		expect(r1.amount1 * 1).to.eq(ETH_IS_0 ? 800 : 8);
		const t2 = getAmounts({
			amountADesired: '10', 
			amountBDesired: '700', 
			amountAMin: '6', 
			amountBMin: '0'
		}, ETH_IS_0);
		const r2 = await router._optimalLiquidityUniV2(uniswapV2Pair.address, t2.amount0Desired, t2.amount1Desired, t2.amount0Min, t2.amount1Min);
		expect(r2.amount0 * 1).to.eq(ETH_IS_0 ? 7 : 700);
		expect(r2.amount1 * 1).to.eq(ETH_IS_0 ? 700 : 7);
		const t3 = getAmounts({
			amountADesired: '5', 
			amountBDesired: '1000', 
			amountAMin: '0', 
			amountBMin: '600'
		}, ETH_IS_0);
		await expectRevert(
			router._optimalLiquidityUniV2(uniswapV2Pair.address, t3.amount0Desired, t3.amount1Desired, t3.amount0Min, t3.amount1Min),
			ETH_IS_0 ? "ImpermaxRouter: INSUFFICIENT_1_AMOUNT" : "ImpermaxRouter: INSUFFICIENT_0_AMOUNT"
		);
		const t4 = getAmounts({
			amountADesired: '10', 
			amountBDesired: '500', 
			amountAMin: '6', 
			amountBMin: '0'
		}, ETH_IS_0);
		await expectRevert(
			router._optimalLiquidityUniV2(uniswapV2Pair.address, t4.amount0Desired, t4.amount1Desired, t4.amount0Min, t4.amount1Min),
			ETH_IS_0 ? "ImpermaxRouter: INSUFFICIENT_0_AMOUNT" : "ImpermaxRouter: INSUFFICIENT_1_AMOUNT"
		);
	});
	
	it('mint', async () => {
		//Mint UNI
		await expectRevert(routerLend.mint(borrowableUNI.address, UNI_LEND_AMOUNT, lender, '0', {from: lender}), "ImpermaxRouter: EXPIRED");
		await expectRevert.unspecified(routerLend.mint(borrowableUNI.address, UNI_LEND_AMOUNT, lender, DEADLINE, {from: lender}));
		await UNI.approve(routerLend.address, UNI_LEND_AMOUNT, {from: lender});
		await routerLend.mint(borrowableUNI.address, UNI_LEND_AMOUNT, lender, DEADLINE, {from: lender});
		expect(await borrowableUNI.balanceOf(lender) * 1).to.eq(UNI_LEND_AMOUNT.sub(MINIMUM_LIQUIDITY) * 1);
		
		//Mint ETH
		await expectRevert(routerLend.mintETH(borrowableUNI.address, lender, DEADLINE, {value: ETH_LEND_AMOUNT, from: lender}), "ImpermaxRouter: NOT_WETH");
		await expectRevert(routerLend.mintETH(borrowableWETH.address, lender, '0', {value: ETH_LEND_AMOUNT, from: lender}), "ImpermaxRouter: EXPIRED");
		op = routerLend.mintETH(borrowableWETH.address, lender, DEADLINE, {value: ETH_LEND_AMOUNT, from: lender});
		await checkETHBalance(op, lender, ETH_LEND_AMOUNT, true);
		expect(await borrowableWETH.balanceOf(lender) * 1).to.eq(ETH_LEND_AMOUNT.sub(MINIMUM_LIQUIDITY) * 1);
	});
	
	it('mintNewCollateral', async () => {
		await expectRevert.unspecified(mintNewCollateral(router, nftlp, borrower, LP_AMOUNT));
		const permitData = await permitGenerator.permit(uniswapV2Pair, borrower, router.address, LP_AMOUNT, DEADLINE);
		const receipt =  await mintNewCollateral(router, nftlp, borrower, LP_AMOUNT);
		TOKEN_ID = receipt.tokenId;
		expect(await collateral.ownerOf(TOKEN_ID)).to.eq(borrower);
		expect(await nftlp.liquidity(TOKEN_ID) * 1).to.eq(LP_AMOUNT * 1);
	});

	it('redeem', async () => {
		const UNI_REDEEM_AMOUNT = await borrowableUNI.balanceOf(lender);
		const ETH_REDEEM_AMOUNT = await borrowableWETH.balanceOf(lender);
		expect(UNI_REDEEM_AMOUNT * 1).to.be.gt(1);
		expect(ETH_REDEEM_AMOUNT * 1).to.be.gt(1);
		
		//Redeem UNI
		await expectRevert(routerLend.redeem(borrowableUNI.address, UNI_REDEEM_AMOUNT, lender, '0', '0x', {from: lender}), "ImpermaxRouter: EXPIRED");
		await expectRevert(routerLend.redeem(borrowableUNI.address, UNI_REDEEM_AMOUNT, lender, DEADLINE, '0x', {from: lender}), "ImpermaxERC20: TRANSFER_NOT_ALLOWED");
		const permitRedeemUNI = await permitGenerator.permit(borrowableUNI, lender, routerLend.address, UNI_REDEEM_AMOUNT, DEADLINE);
		await routerLend.redeem(borrowableUNI.address, UNI_REDEEM_AMOUNT, lender, DEADLINE, permitRedeemUNI, {from: lender});
		expect(await UNI.balanceOf(lender) * 1).to.eq(UNI_REDEEM_AMOUNT * 1);
		
		//Redeem ETH
		await expectRevert(routerLend.redeemETH(borrowableUNI.address, UNI_REDEEM_AMOUNT, lender, DEADLINE, '0x', {from: lender}), "ImpermaxRouter: NOT_WETH");
		await expectRevert(routerLend.redeemETH(borrowableWETH.address, ETH_REDEEM_AMOUNT, lender, '0', '0x', {from: lender}), "ImpermaxRouter: EXPIRED");
		await expectRevert(routerLend.redeemETH(borrowableWETH.address, ETH_REDEEM_AMOUNT, lender, DEADLINE, '0x', {from: lender}), "ImpermaxERC20: TRANSFER_NOT_ALLOWED");
		const permitRedeemETH = await permitGenerator.permit(borrowableWETH, lender, routerLend.address, ETH_REDEEM_AMOUNT, DEADLINE);
		const op = routerLend.redeemETH(borrowableWETH.address, ETH_REDEEM_AMOUNT, lender, DEADLINE, permitRedeemETH, {from: lender});
		await checkETHBalance(op, lender, ETH_REDEEM_AMOUNT);
				
		//Restore initial state
		await UNI.approve(routerLend.address, UNI_REDEEM_AMOUNT, {from: lender});
		await routerLend.mint(borrowableUNI.address, UNI_REDEEM_AMOUNT, lender, DEADLINE, {from: lender});
		await routerLend.mintETH(borrowableWETH.address, lender, DEADLINE, {value: ETH_REDEEM_AMOUNT, from: lender});		
	});
	
	it('redeem and remint collateral', async () => {
		// Redeem 20%
		const redeemAmount = LP_AMOUNT.div(new BN(5));
		let redeemAmountUNI = UNI_LP_AMOUNT.div(new BN(5));
		const redeemAmountETH = ETH_LP_AMOUNT.div(new BN(5));
		const permitDataNft1 = await permitGenerator.nftPermit(collateral, borrower, router.address, TOKEN_ID, DEADLINE);
		const op = redeemCollateralETH(router, nftlp, borrower, TOKEN_ID, bnMantissa(0.2), ETH_IS_0);
		await checkETHBalance(op, borrower, redeemAmountETH, false);
		expect(await UNI.balanceOf(borrower)*1).to.eq(redeemAmountUNI*1);
		redeemAmountUNI = await UNI.balanceOf(borrower); // adjust for actual amount
		// Mint new position
		await UNI.approve(router.address, redeemAmountUNI, {from: borrower});
		const receipt =  await mintCollateralETH(router, nftlp, borrower, MAX_UINT_256, 0, redeemAmountETH, redeemAmountUNI, 0, 0, ETH_IS_0, ETH_IS_0);
		TOKEN_2 = receipt.tokenId;
		expect(await collateral.ownerOf(TOKEN_2)).to.eq(borrower);
		expect(await nftlp.liquidity(TOKEN_2) * 1).to.eq(redeemAmount * 1);
		// Redeem 100%
		const permitDataNft2 = await permitGenerator.nftPermit(collateral, borrower, router.address, TOKEN_2, DEADLINE);
		const op2 = redeemCollateralETH(router, nftlp, borrower, TOKEN_2, oneMantissa, ETH_IS_0);
		await checkETHBalance(op2, borrower, redeemAmountETH, false);
		expect(await UNI.balanceOf(borrower)*1).to.eq(redeemAmountUNI*1);
		// Mint to old position
		await UNI.approve(router.address, redeemAmountUNI, {from: borrower});
		await mintCollateralETH(router, nftlp, borrower, TOKEN_ID, 0, redeemAmountETH, redeemAmountUNI, 0, 0, ETH_IS_0, ETH_IS_0);
		expect(await nftlp.liquidity(TOKEN_ID) * 1).to.eq(LP_AMOUNT * 1);
	});
	
	it('borrow', async () => {
		//Borrow UNI
		await expectRevert(borrow(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 1 : 0, UNI_BORROW_AMOUNT), "ImpermaxV3Borrowable: BORROW_NOT_ALLOWED");
		const permitBorrowUNI = await permitGenerator.borrowPermit(borrowableUNI, borrower, router.address, UNI_BORROW_AMOUNT, DEADLINE);
		//await expectRevert(borrowETH(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 1 : 0, UNI_BORROW_AMOUNT), "ImpermaxRouter: UNEXPECTED_WETH_0_BALANCE");
		await borrow(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 1 : 0, UNI_BORROW_AMOUNT);
		expect(await UNI.balanceOf(borrower) * 1).to.eq(UNI_BORROW_AMOUNT * 1);
		expect(await borrowableUNI.borrowBalance(TOKEN_ID) * 1).to.eq(UNI_BORROW_AMOUNT * 1);
		
		//Borrow ETH
		await expectRevert(borrowETH(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 0 : 1, ETH_BORROW_AMOUNT), "ImpermaxV3Borrowable: BORROW_NOT_ALLOWED");
		const permitBorrowETH = await permitGenerator.borrowPermit(borrowableWETH, borrower, router.address, ETH_BORROW_AMOUNT, DEADLINE);
		const op = borrowETH(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 0 : 1, ETH_BORROW_AMOUNT);
		await checkETHBalance(op, borrower, ETH_BORROW_AMOUNT);
		const borrowBalanceETH = ETH_BORROW_AMOUNT.mul(new BN(1001)).div(new BN(1000));
		expect(await borrowableWETH.borrowBalance(TOKEN_ID) * 1).to.eq(ETH_BORROW_AMOUNT * 1);
	});
	
	it('repay', async () => {
		//Repay UNI
		await expectRevert.unspecified(repay(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 1 : 0, UNI_REPAY_AMOUNT1));
		await UNI.approve(router.address, UNI_REPAY_AMOUNT1, {from: borrower});
		const expectedUNIBalance = (await UNI.balanceOf(borrower)).sub(UNI_REPAY_AMOUNT1);
		const expectedUNIBorrowed = (await borrowableUNI.borrowBalance(TOKEN_ID)).sub(UNI_REPAY_AMOUNT1);
		await repay(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 1 : 0, UNI_REPAY_AMOUNT1);
		expect(await UNI.balanceOf(borrower) * 1).to.eq(expectedUNIBalance * 1);
		expectAlmostEqualMantissa(await borrowableUNI.borrowBalance(TOKEN_ID), expectedUNIBorrowed);
		
		//Repay ETH
		//await expectRevert(routerLend.repayETH(borrowableUNI.address, TOKEN_ID, DEADLINE, {value: ETH_REPAY_AMOUNT1, from: borrower}), "ImpermaxRouter: NOT_WETH");
		const expectedETHBorrowed = (await borrowableWETH.borrowBalance(TOKEN_ID)).sub(ETH_REPAY_AMOUNT1);
		const op = repayETH(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 0 : 1, ETH_REPAY_AMOUNT1);
		await checkETHBalance(op, borrower, ETH_REPAY_AMOUNT1, true);
		expectAlmostEqualMantissa(await borrowableWETH.borrowBalance(TOKEN_ID), expectedETHBorrowed);
	});
	
	it('repay exceeding borrowed', async () => {
		//Repay UNI
		await UNI.mint(borrower, UNI_REPAY_AMOUNT2);
		const borrowedUNI = await borrowableUNI.borrowBalance(TOKEN_ID,);
		expect(borrowedUNI*1).to.be.lt(UNI_REPAY_AMOUNT2*1);
		await UNI.approve(router.address, UNI_REPAY_AMOUNT2, {from: borrower});
		const expectedUNIBalance = (await UNI.balanceOf(borrower)).sub(borrowedUNI);
		const expectedUNIBorrowed = 0;
		await repay(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 1 : 0, UNI_REPAY_AMOUNT2);
		expectAlmostEqualMantissa(await UNI.balanceOf(borrower), expectedUNIBalance);
		expect(await borrowableUNI.borrowBalance(TOKEN_ID,) * 1).to.eq(expectedUNIBorrowed * 1);
		
		//Repay ETH
		const borrowedETH = await borrowableWETH.borrowBalance(TOKEN_ID);
		expect(borrowedETH*1).to.be.lt(ETH_REPAY_AMOUNT2*1);
		const expectedETHBorrowed = 0;
		const op = repayETH(router, nftlp, borrower, TOKEN_ID, ETH_IS_0 ? 0 : 1, ETH_REPAY_AMOUNT2);
		await checkETHBalance(op, borrower, borrowedETH, true);
		expect(await borrowableWETH.borrowBalance(TOKEN_ID,) * 1).to.eq(expectedETHBorrowed * 1);
	});
	
	it('leverage', async () => {
		// TODO reinstate revert tests
		/*await expectRevert(
			leverage(router, nftlp, borrower, TOKEN_ID, '100', '8000', '90', '7000', '0x', '0x', ETH_IS_0),
			ETH_IS_0 ? "ImpermaxRouter: INSUFFICIENT_0_AMOUNT" : "ImpermaxRouter: INSUFFICIENT_1_AMOUNT"
		);
		await expectRevert(
			leverage(router, nftlp, borrower, TOKEN_ID, '80', '10000', '70', '9000', '0x', '0x', ETH_IS_0),
			ETH_IS_0 ? "ImpermaxRouter: INSUFFICIENT_1_AMOUNT" : "ImpermaxRouter: INSUFFICIENT_0_AMOUNT"
		);
		await expectRevert( 
			leverage(router, nftlp, borrower, TOKEN_ID, ETH_LEVERAGE_AMOUNT, UNI_LEVERAGE_AMOUNT, '0', '0', '0x', '0x', ETH_IS_0),
			'ImpermaxV3Borrowable: BORROW_NOT_ALLOWED'
		);*/
		
		const permitBorrowUNIHigh = await permitGenerator.borrowPermit(borrowableUNI, borrower, router.address, UNI_LEVERAGE_AMOUNT_HIGH, DEADLINE);
		const permitBorrowETHHigh = await permitGenerator.borrowPermit(borrowableWETH, borrower, router.address, ETH_LEVERAGE_AMOUNT_HIGH, DEADLINE);
		await expectRevert(
			leverage(router, nftlp, borrower, TOKEN_ID, ETH_LEVERAGE_AMOUNT_HIGH, 
				UNI_LEVERAGE_AMOUNT_HIGH, '0', '0', permitBorrowETHHigh, permitBorrowUNIHigh, ETH_IS_0), 
			'ImpermaxV3Borrowable: INSUFFICIENT_LIQUIDITY'
		);

		const balancePrior = await nftlp.liquidity(TOKEN_ID);
		const permitBorrowUNI = await permitGenerator.borrowPermit(borrowableUNI, borrower, router.address, UNI_LEVERAGE_AMOUNT, DEADLINE);
		const permitBorrowETH = await permitGenerator.borrowPermit(borrowableWETH, borrower, router.address, ETH_LEVERAGE_AMOUNT, DEADLINE);
		const receipt = await leverage(router, nftlp, borrower, TOKEN_ID, ETH_LEVERAGE_AMOUNT, UNI_LEVERAGE_AMOUNT, ETH_LEVERAGE_AMOUNT, EXPECTED_UNI_LEVERAGE_AMOUNT, permitBorrowETH, permitBorrowUNI, ETH_IS_0);
		const balanceAfter = await nftlp.liquidity(TOKEN_ID);
		const expectedDiff = LP_AMOUNT.mul(LEVERAGE.sub(new BN(1)));
		//console.log(balancePrior / 1e18);
		//console.log(balanceAfter / 1e18);
		console.log(receipt.receipt.gasUsed);
		expectAlmostEqualMantissa(balanceAfter.sub(balancePrior), expectedDiff);
		expect(await borrowableUNI.borrowBalance(TOKEN_ID) * 1).to.eq(EXPECTED_UNI_LEVERAGE_AMOUNT * 1);
		expect(await borrowableWETH.borrowBalance(TOKEN_ID) * 1).to.eq(ETH_LEVERAGE_AMOUNT * 1);
	});
	
	it('liquidate', async () => {
		// Change oracle price
		await UNI.mint(uniswapV2Pair.address, UNI_BUY);
		await uniswapV2Pair.swap(ETH_IS_0 ? ETH_BOUGHT : '0', ETH_IS_0 ? '0' : ETH_BOUGHT, address(0), '0x');
		await simpleUniswapOracle.getResult(uniswapV2Pair.address);
		await expectRevert(
			routerLend.liquidate(borrowableUNI.address, TOKEN_ID, '0', liquidator, DEADLINE, {from: liquidator}),
			"ImpermaxV3Collateral: INSUFFICIENT_SHORTFALL"
		);
		await increaseTime(3700);
		await borrowableUNI.accrueInterest();
		await borrowableWETH.accrueInterest();
		
		// Liquidate UNI
		const UNIBorrowedPrior = await borrowableUNI.borrowBalance(TOKEN_ID);
		const borrowerBalance0 = await nftlp.liquidity(TOKEN_ID);
		await UNI.mint(liquidator, UNI_LIQUIDATE_AMOUNT);
		await expectRevert(routerLend.liquidate(borrowableUNI.address, TOKEN_ID, '0', liquidator, '0', {from: liquidator}),"ImpermaxRouter: EXPIRED");
		await expectRevert.unspecified(routerLend.liquidate(borrowableUNI.address, TOKEN_ID, UNI_LIQUIDATE_AMOUNT, liquidator, DEADLINE, {from: liquidator}));
		await UNI.approve(routerLend.address, UNI_LIQUIDATE_AMOUNT, {from: liquidator});
		const liquidateUNIResult = await routerLend.liquidate.call(borrowableUNI.address, TOKEN_ID, UNI_LIQUIDATE_AMOUNT, liquidator, DEADLINE, {from: liquidator});
		await routerLend.liquidate(borrowableUNI.address, TOKEN_ID, UNI_LIQUIDATE_AMOUNT, liquidator, DEADLINE, {from: liquidator});
		const UNIBorrowedAfter = await borrowableUNI.borrowBalance(TOKEN_ID);
		const lpBalance1 = await nftlp.liquidity(TOKEN_ID);
		const borrowerBalance1 = await nftlp.liquidity(TOKEN_ID);
		const seizeTokens1 = await nftlp.liquidity(liquidateUNIResult.seizeTokenId);
		expect(await nftlp.ownerOf(liquidateUNIResult.seizeTokenId)).to.eq(liquidator);
		expect(await UNI.balanceOf(liquidator) * 1).to.eq(0);
		expect(liquidateUNIResult.amount * 1).to.eq(UNI_LIQUIDATE_AMOUNT * 1);
		expectAlmostEqualMantissa(UNIBorrowedAfter, UNIBorrowedPrior.sub(UNI_LIQUIDATE_AMOUNT));
		expect(borrowerBalance0.sub(borrowerBalance1) * 1).to.eq(seizeTokens1 * 1);
		
		// Liquidate ETH
		const ETHBorrowedPrior = await borrowableWETH.borrowBalance(TOKEN_ID);
		await expectRevert(routerLend.liquidateETH(borrowableUNI.address, TOKEN_ID, liquidator, DEADLINE, {value: ETH_LIQUIDATE_AMOUNT, from: liquidator}),"ImpermaxRouter: NOT_WETH");
		await expectRevert(routerLend.liquidateETH(borrowableWETH.address, TOKEN_ID, liquidator, '0', {value: ETH_LIQUIDATE_AMOUNT, from: liquidator}),"ImpermaxRouter: EXPIRED");
		const liquidateETHResult = await routerLend.liquidateETH.call(borrowableWETH.address, TOKEN_ID, liquidator, DEADLINE, {value: ETH_LIQUIDATE_AMOUNT, from: liquidator});
		console.log("amounteth", liquidateETHResult.amountETH / 1e18);
		const op = routerLend.liquidateETH(borrowableWETH.address, TOKEN_ID, liquidator, DEADLINE, {value: ETH_LIQUIDATE_AMOUNT, from: liquidator});
		await checkETHBalance(op, liquidator, ETH_LIQUIDATE_AMOUNT, true);
		const ETHBorrowedAfter = await borrowableWETH.borrowBalance(TOKEN_ID);
		const borrowerBalance2 = await nftlp.liquidity(TOKEN_ID);
		const seizeTokens2 = await nftlp.liquidity(liquidateETHResult.seizeTokenId);
		expect(await nftlp.ownerOf(liquidateETHResult.seizeTokenId)).to.eq(liquidator);
		expect(liquidateETHResult.amountETH * 1).to.eq(ETH_LIQUIDATE_AMOUNT * 1);
		expectAlmostEqualMantissa(ETHBorrowedAfter, ETHBorrowedPrior.sub(ETH_LIQUIDATE_AMOUNT));
		expectAlmostEqualMantissa(borrowerBalance1.sub(borrowerBalance2), seizeTokens2);
		
		// Liquidate MAX
		const expectedUNIAmount = await borrowableUNI.borrowBalance(TOKEN_ID);
		const expectedETHAmount = await borrowableWETH.borrowBalance(TOKEN_ID);
		await UNI.mint(liquidator, UNI_LIQUIDATE_AMOUNT2);
		await UNI.approve(routerLend.address, UNI_LIQUIDATE_AMOUNT2, {from: liquidator});
		const liquidateUNIResult2 = await routerLend.liquidate.call(borrowableUNI.address, TOKEN_ID, UNI_LIQUIDATE_AMOUNT2, liquidator, DEADLINE, {from: liquidator});
		expectAlmostEqualMantissa(liquidateUNIResult2.amount, expectedUNIAmount);
		const op2 = routerLend.liquidateETH(borrowableWETH.address, TOKEN_ID, liquidator, DEADLINE, {value: ETH_LIQUIDATE_AMOUNT2, from: liquidator});
		await checkETHBalance(op2, liquidator, expectedETHAmount, true);
	});
	
	// TODO REWRITE THESE 2 FUNCTIONS
	/*it('impermaxBorrow is forbidden to non-borrowable', async () => {
		// Fails because data cannot be empty
		await expectRevert.unspecified(router.impermaxBorrow(router.address, '0', '0', '0x'));
		const data = encode(
			['uint8', 'address', 'uint8', 'bytes'],
			[0, nftlp.address, 0, '0x']
		);
		// Fails becasue msg.sender is not a borrowable
		await expectRevert(router.impermaxBorrow(router.address, '0', '0', data), 'ImpermaxRouter: UNAUTHORIZED_CALLER');
		// Fails because sender is not the router
		const borrowableA = ETH_IS_0 ? borrowableWETH : borrowableUNI;
		await expectRevert(borrowableA.borrow(TOKEN_ID, router.address, '0', data), 'ImpermaxRouter: FROM_NOT_ROUTER');
	});
	
	it('onERC721Received is forbidden to non-nftlp', async () => {
		// Succeed if data is empty
		await router.onERC721Received(address(0), router.address, '0', '0x');
		const data = encode(
			['uint8', 'address', 'uint8', 'bytes'],
			[0, nftlp.address, 0, '0x']
		);
		// Fails becasue msg.sender is not the nftlp
		await expectRevert(router.onERC721Received(collateral.address, router.address, '0', data), 'ImpermaxRouter: SENDER_NOT_NFTLP');
		// Fails becasue nft is not sent by the collateral
		await router.repay(borrowableUNI.address, TOKEN_ID, bnMantissa(500), DEADLINE, {from: liquidator});
		console.log(await nftlp.liquidity(TOKEN_ID) / 1e18);
		const newTokenId = await collateral.redeem.call(router.address, TOKEN_ID, bnMantissa(0.01), {from: borrower});
		await collateral.redeem(borrower, TOKEN_ID, bnMantissa(0.1), {from: borrower});
		console.log(nftlp.contract.methods['safeTransferFrom(address,address,uint256,bytes)']);
		await expectRevert(nftlp.contract.methods['safeTransferFrom(address,address,uint256,bytes)'](borrower, router.address, newTokenId, data, {from: borrower}), 'ImpermaxRouter: UNAUTHORIZED_CALLER');
		//await nftlp.join(TOKEN_ID, newTokenId, {from: borrower});
		// Fails because sender is not the router
		await expectRevert(collateral.redeem(router.address, TOKEN_ID, oneMantissa, data, {from: borrower}), 'ImpermaxRouter: FROM_NOT_ROUTER');
	});*/
	/*
	it('address calculation', async () => {
		//console.log(keccak256(Collateral.bytecode));
		//console.log(keccak256(Borrowable.bytecode));
		//console.log(await router.getLendingPool(uniswapV2Pair.address));
		const expectedBorrowableA = ETH_IS_0 ? borrowableWETH.address : borrowableUNI.address;
		const expectedBorrowableB = ETH_IS_0 ? borrowableUNI.address : borrowableWETH.address;
		const expectedCollateral = collateral.address;
		expect(await router.getBorrowable(uniswapV2Pair.address, '0')).to.eq(expectedBorrowableA);
		expect(await router.getBorrowable(uniswapV2Pair.address, '1')).to.eq(expectedBorrowableB);
		expect(await router.getCollateral(uniswapV2Pair.address)).to.eq(expectedCollateral);
		const lendingPool = await router.getLendingPool(uniswapV2Pair.address);
		expect(lendingPool.borrowableA).to.eq(expectedBorrowableA);
		expect(lendingPool.borrowableB).to.eq(expectedBorrowableB);
		expect(lendingPool.collateral).to.eq(expectedCollateral);
		const receipt = await router.getBorrowable.sendTransaction(uniswapV2Pair.address, '0');
		//console.log(receipt.receipt.gasUsed); // costs around 1800
	});*/
	
	it('max approve', async () => {
		//Redeem ETH
		await expectRevert(routerLend.redeemETH(borrowableWETH.address, MAX_APPROVE_ETH_AMOUNT, lender, DEADLINE, '0x', {from: lender}), "ImpermaxERC20: TRANSFER_NOT_ALLOWED");
		expect(await borrowableWETH.allowance(lender, routerLend.address) * 1).to.eq(0);
		const permitRedeemETH = await permitGenerator.permit(borrowableWETH, lender, routerLend.address, MAX_UINT_256, DEADLINE);
		await routerLend.redeemETH(borrowableWETH.address, MAX_APPROVE_ETH_AMOUNT, lender, DEADLINE, permitRedeemETH, {from: lender});
		expect(await borrowableWETH.allowance(lender, routerLend.address) * 1).to.eq(MAX_UINT_256 * 1);
	});
	
	it('router balance is always 0', async () => {
		expect(await UNI.balanceOf(routerLend.address) * 1).to.eq(0);
		expect(await WETH.balanceOf(routerLend.address) * 1).to.eq(0);
		expect(await borrowableUNI.balanceOf(routerLend.address) * 1).to.eq(0);
		expect(await borrowableWETH.balanceOf(routerLend.address) * 1).to.eq(0);
		expect(await collateral.balanceOf(routerLend.address) * 1).to.eq(0);
		expect(await web3.eth.getBalance(routerLend.address) * 1).to.eq(0);
		expect(await UNI.balanceOf(router.address) * 1).to.eq(0);
		expect(await WETH.balanceOf(router.address) * 1).to.eq(0);
		expect(await borrowableUNI.balanceOf(router.address) * 1).to.eq(0);
		expect(await borrowableWETH.balanceOf(router.address) * 1).to.eq(0);
		expect(await collateral.balanceOf(router.address) * 1).to.eq(0);
		expect(await web3.eth.getBalance(router.address) * 1).to.eq(0);
	});
});