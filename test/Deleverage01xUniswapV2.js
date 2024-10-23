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
	leverage,
	mintAndLeverage,
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
const Router01V3 = artifacts.require('Router01V3');
const Router01V3_0 = artifacts.require('Router01V3_0');
const TokenizedUniswapV2Factory = artifacts.require('TokenizedUniswapV2Factory');
const TokenizedUniswapV2Position = artifacts.require('TokenizedUniswapV2Position');
const WETH9 = artifacts.require('WETH9');

const oneMantissa = (new BN(10)).pow(new BN(18));
const UNI_LP_AMOUNT = oneMantissa;
const ETH_LP_AMOUNT = oneMantissa.div(new BN(100));
const UNI_LEND_AMOUNT = oneMantissa.mul(new BN(10));
const ETH_LEND_AMOUNT = oneMantissa.div(new BN(10));
const UNI_BORROW_AMOUNT = UNI_LP_AMOUNT.div(new BN(2));
const ETH_BORROW_AMOUNT = ETH_LP_AMOUNT.div(new BN(2));
const UNI_LEVERAGE_AMOUNT = oneMantissa.mul(new BN(6));
const ETH_LEVERAGE_AMOUNT = oneMantissa.mul(new BN(6)).div(new BN(100));
const LEVERAGE = new BN(7);
const DLVRG = new BN(5);
const UNI_DLVRG_AMOUNT = oneMantissa.mul(new BN(5));
const ETH_DLVRG_AMOUNT = oneMantissa.mul(new BN(5)).div(new BN(100));
const DLVRG_REFUND_NUM = new BN(13);
const DLVRG_REFUND_DEN = new BN(2);

let LP_AMOUNT;
let TOKEN_ID;
let ETH_IS_A;
const INITIAL_EXCHANGE_RATE = oneMantissa;
const MINIMUM_LIQUIDITY = new BN(1000);

contract('Deleverage01xUniswapV2', function (accounts) {
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
	
	beforeEach(async () => {
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
		// Initialize UNI pair
		await UNI.mint(uniswapV2PairAddress, UNI_LP_AMOUNT);
		await WETH.deposit({value: ETH_LP_AMOUNT});
		await WETH.transfer(uniswapV2PairAddress, ETH_LP_AMOUNT);
		await uniswapV2Pair.mint(root);
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
		ETH_IS_A = await borrowable0.underlying() == WETH.address;
		if (ETH_IS_A) [borrowableWETH, borrowableUNI] = [borrowable0, borrowable1];
		else [borrowableWETH, borrowableUNI] = [borrowable1, borrowable0]
		router = await Router01V3.new(impermaxFactory.address, WETH.address);
		routerLend = await Router01V3_0.new(impermaxFactory.address, WETH.address);
		await increaseTime(3700); // wait for oracle to be ready
		await permitGenerator.initialize();
		
		//Mint UNI
		await UNI.approve(routerLend.address, UNI_LEND_AMOUNT, {from: lender});
		await routerLend.mint(borrowableUNI.address, UNI_LEND_AMOUNT, lender, DEADLINE, {from: lender});
		//Mint ETH
		await routerLend.mintETH(borrowableWETH.address, lender, DEADLINE, {value: ETH_LEND_AMOUNT, from: lender});
		//Mint LP TOOD mintAndLeverage
		await UNI.approve(router.address, UNI_LP_AMOUNT, {from: borrower});
		await WETH.approve(router.address, ETH_LP_AMOUNT, {from: borrower});
		//const permitData = await permitGenerator.permit(uniswapV2Pair, borrower, routerLend.address, LP_AMOUNT, DEADLINE);
		//TOKEN_ID = await routerLend.mintNewCollateral.call(nftlp.address, LP_AMOUNT, borrower, DEADLINE, permitData, {from: borrower});
		//await routerLend.mintNewCollateral(nftlp.address, LP_AMOUNT, borrower, DEADLINE, permitData, {from: borrower});
		//Leverage
		const permitBorrowUNI = await permitGenerator.borrowPermit(borrowableUNI, borrower, router.address, UNI_LEVERAGE_AMOUNT, DEADLINE);
		const permitBorrowETH = await permitGenerator.borrowPermit(borrowableWETH, borrower, router.address, ETH_LEVERAGE_AMOUNT, DEADLINE);
		//await leverage(router, nftlp, borrower, TOKEN_ID, ETH_LEVERAGE_AMOUNT, UNI_LEVERAGE_AMOUNT, '0', '0', permitBorrowETH, permitBorrowUNI, ETH_IS_A);
		const receipt = await mintAndLeverage(router, nftlp, borrower, ETH_LP_AMOUNT, UNI_LP_AMOUNT, ETH_LEVERAGE_AMOUNT.add(ETH_LP_AMOUNT), UNI_LEVERAGE_AMOUNT.add(UNI_LP_AMOUNT), '0', '0', permitBorrowETH, permitBorrowUNI, ETH_IS_A);
		TOKEN_ID = receipt.returnValue;
		LP_AMOUNT = await nftlp.liquidity(TOKEN_ID);
		console.log(receipt.receipt.gasUsed);
	});
	
	it('deleverage', async () => {
		const LP_DLVRG_TOKENS = LP_AMOUNT.mul(DLVRG).div(LEVERAGE);
		const ETH_DLVRG_MIN = ETH_DLVRG_AMOUNT.mul(new BN(9999)).div(new BN(10000));
		const ETH_DLVRG_HIGH = ETH_DLVRG_AMOUNT.mul(new BN(10001)).div(new BN(10000));
		const UNI_DLVRG_MIN = UNI_DLVRG_AMOUNT.mul(new BN(9999)).div(new BN(10000));
		const UNI_DLVRG_HIGH = UNI_DLVRG_AMOUNT.mul(new BN(10001)).div(new BN(10000));
		
		await expectRevert(
			deleverage(router, nftlp, borrower, TOKEN_ID, LP_DLVRG_TOKENS, ETH_DLVRG_MIN, UNI_DLVRG_MIN, '0x', ETH_IS_A),
			'ImpermaxERC721: UNAUTHORIZED'
		);
		const permit = await permitGenerator.nftPermit(collateral, borrower, router.address, TOKEN_ID, DEADLINE);
		await expectRevert(
			deleverage(router, nftlp, borrower, TOKEN_ID, new BN(0), ETH_DLVRG_MIN, UNI_DLVRG_MIN, permit, ETH_IS_A),
			"ImpermaxRouter: REDEEM_ZERO"
		);
		await expectRevert(
			deleverage(router, nftlp, borrower, TOKEN_ID, LP_DLVRG_TOKENS, ETH_DLVRG_HIGH, UNI_DLVRG_MIN, permit, ETH_IS_A),
			ETH_IS_A ? "ImpermaxRouter: INSUFFICIENT_0_AMOUNT" : "ImpermaxRouter: INSUFFICIENT_1_AMOUNT"
		);
		await expectRevert(
			deleverage(router, nftlp, borrower, TOKEN_ID, LP_DLVRG_TOKENS, ETH_DLVRG_MIN, UNI_DLVRG_HIGH, permit, ETH_IS_A),
			ETH_IS_A ? "ImpermaxRouter: INSUFFICIENT_1_AMOUNT" : "ImpermaxRouter: INSUFFICIENT_0_AMOUNT"
		);
		
		const balancePrior = await nftlp.liquidity(TOKEN_ID);
		const borrowBalanceUNIPrior = await borrowableUNI.borrowBalance(TOKEN_ID);
		const borrowBalanceETHPrior = await borrowableWETH.borrowBalance(TOKEN_ID);
		const receipt = await deleverage(router, nftlp, borrower, TOKEN_ID, LP_DLVRG_TOKENS, ETH_DLVRG_MIN, UNI_DLVRG_MIN, permit, ETH_IS_A);
		const balanceAfter = await nftlp.liquidity(TOKEN_ID);
		const borrowBalanceUNIAfter = await borrowableUNI.borrowBalance(TOKEN_ID);
		const borrowBalanceETHAfter = await borrowableWETH.borrowBalance(TOKEN_ID);
		//console.log(balancePrior / 1e18, balanceAfter / 1e18);
		//console.log(borrowBalanceUNIPrior / 1e18, borrowBalanceUNIAfter / 1e18);
		//console.log(borrowBalanceETHPrior / 1e18, borrowBalanceETHAfter / 1e18);
		console.log(receipt.receipt.gasUsed);		
		expectAlmostEqualMantissa(balancePrior.sub(balanceAfter), LP_DLVRG_TOKENS);
		expectAlmostEqualMantissa(borrowBalanceUNIPrior.sub(borrowBalanceUNIAfter), UNI_DLVRG_AMOUNT);
		expectAlmostEqualMantissa(borrowBalanceETHPrior.sub(borrowBalanceETHAfter), ETH_DLVRG_AMOUNT);
	});
	
	it('deleverage with refund UNI', async () => {
		const LP_DLVRG_TOKENS = DLVRG_REFUND_NUM.mul(LP_AMOUNT).div(DLVRG_REFUND_DEN).div(LEVERAGE);
		const permit = await permitGenerator.nftPermit(collateral, borrower, router.address, TOKEN_ID, DEADLINE);
		
		const ETHBalancePrior = await web3.eth.getBalance(borrower);
		const UNIBalancePrior = await UNI.balanceOf(borrower);
		const receipt = await deleverage(router, nftlp, borrower, TOKEN_ID, LP_DLVRG_TOKENS, '0', '0', permit, ETH_IS_A);
		const ETHBalanceAfter = await web3.eth.getBalance(borrower);
		const UNIBalanceAfter = await UNI.balanceOf(borrower);
		console.log(receipt.receipt.gasUsed);		
		expect(await borrowableWETH.borrowBalance(TOKEN_ID) * 1).to.eq(0);
		expect(await borrowableUNI.borrowBalance(TOKEN_ID) * 1).to.eq(0);
		// Todo uncomment this once ETH is supported
		//expect(ETHBalanceAfter - ETHBalancePrior).to.gt(0);
		expect(UNIBalanceAfter.sub(UNIBalancePrior) * 1).to.gt(0);
	});
});