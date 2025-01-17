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
	routerManager,
	mintCollateralETHUniV3,
	getMintCollateralETHUniV3Action,
	getMintAndLeverageETHUniV3Action,
	getDeleverageETHUniV3Action,
	permitGenerator,
} = require('./Utils/ImpermaxPeriphery');
const { keccak256, toUtf8Bytes } = require('ethers/utils');

const MockERC20 = artifacts.require('MockERC20');
const UniswapV3Factory = artifacts.require('UniswapV3Factory');
const UniswapV3Pool = artifacts.require('UniswapV3Pool');
const Factory = artifacts.require('ImpermaxV3Factory');
const BDeployer = artifacts.require('BDeployer');
const CDeployer = artifacts.require('CDeployer');
const Collateral = artifacts.require('ImpermaxV3Collateral');
const Borrowable = artifacts.require('ImpermaxV3Borrowable');
const ImpermaxV3UniV3Router01 = artifacts.require('ImpermaxV3UniV3Router01');
const ImpermaxV3LendRouter01 = artifacts.require('ImpermaxV3LendRouter01');
const TokenizedUniswapV3Factory = artifacts.require('TokenizedUniswapV3Factory');
const TokenizedUniswapV3Position = artifacts.require('TokenizedUniswapV3Position');
const WETH9 = artifacts.require('WETH9');

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

function X96(n) {
	return _2_96.mul(bnMantissa(n)).div(oneMantissa);
}
function sqrtX96(n) {
	return X96(Math.sqrt(n));
}

const MAX_UINT_256 = (new BN(2)).pow(new BN(256)).sub(new BN(1));
const oneMantissa = (new BN(10)).pow(new BN(18));
const _2_96 = (new BN(2)).pow(new BN(96));
const ZERO = new BN(0);

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
let price;
let priceA;
let priceB;

const FEE = new BN(500);

contract('ImpermaxV3UniV3Router01', function (accounts) {
	let root = accounts[0];
	let borrower = accounts[1];
	let lender = accounts[2];
	let liquidator = accounts[3];
	
	let uniswapV3Factory;
	let tokenizedUniswapV3Factory;
	let impermaxFactory;
	let WETH;
	let UNI;
	let uniswapV3Pool;
	let nftlp;
	let collateral;
	let borrowableWETH;
	let borrowableUNI;
	
	let router;
	let routerLend;
	
	it('do', async () => {
		uniswapV3Factory = await UniswapV3Factory.new();
		tokenizedUniswapV3Factory = await TokenizedUniswapV3Factory.new(uniswapV3Factory.address);
		const bDeployer = await BDeployer.new();
		const cDeployer = await CDeployer.new();
		impermaxFactory = await Factory.new(address(0), address(0), bDeployer.address, cDeployer.address);
		WETH = await WETH9.new();
		UNI = await MockERC20.new('Uniswap', 'UNI');
		const uniswapV3PoolAddress = await uniswapV3Factory.createPool.call(WETH.address, UNI.address, FEE);
		await uniswapV3Factory.createPool(WETH.address, UNI.address, FEE);
		uniswapV3Pool = await UniswapV3Pool.at(uniswapV3PoolAddress);
		const nftlpAddress = await tokenizedUniswapV3Factory.createNFTLP.call(WETH.address, UNI.address);
		await tokenizedUniswapV3Factory.createNFTLP(WETH.address, UNI.address);
		nftlp = await TokenizedUniswapV3Position.at(nftlpAddress);
		await UNI.mint(lender, UNI_LEND_AMOUNT);
		//await WETH.deposit({value: ETH_LP_AMOUNT, from: borrower});
		//await UNI.transfer(uniswapV3PoolAddress, UNI_LP_AMOUNT, {from: borrower});
		//await WETH.transfer(uniswapV3PoolAddress, ETH_LP_AMOUNT, {from: borrower});
		//await uniswapV3Pool.mint(borrower);
		//LP_AMOUNT = await uniswapV3Pool.balanceOf(borrower);
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
		else [borrowableWETH, borrowableUNI] = [borrowable1, borrowable0];
		await increaseTime(3700); // wait for oracle to be ready
		await permitGenerator.initialize();
		
		// deploy routers
		await routerManager.initialize();
		await routerManager.initializePoolToken(WETH.address);
		await routerManager.initializeUniV3(impermaxFactory.address, uniswapV3Factory.address, WETH.address);
		router = routerManager.uniV3;
		routerLend = routerManager.poolToken;
		
		price = ETH_IS_0 ? 300 : 1/300;
		priceA = ETH_IS_0 ? 50000 : "-65000";
		priceB = ETH_IS_0 ? 65000 : "-50000";
		await uniswapV3Pool.initialize(sqrtX96(price));
		
		console.log(ETH_IS_0, WETH.address, UNI.address)
		

		const ETH_LP_AMOUNT = bnMantissa(1);
		const UNI_LP_AMOUNT = bnMantissa(300);
		await UNI.mint(borrower, UNI_LP_AMOUNT);
		await UNI.approve(router.address, UNI_LP_AMOUNT, {from: borrower});

		//const balancePrior = await web3.eth.getBalance(borrower)		
		const receipt = await mintCollateralETHUniV3(router, nftlp, borrower, MAX_UINT_256, FEE, new BN(priceA), new BN(priceB), ETH_LP_AMOUNT, UNI_LP_AMOUNT, bnMantissa(0.99), bnMantissa(270), ETH_IS_0, ETH_IS_0);
		//const balanceAfter = await web3.eth.getBalance(borrower);
		//const gasUsed = receipt.receipt.gasUsed * 1e9;
		//console.log("balancePrior", balancePrior / 1e18);
		//console.log("balanceAfter", balanceAfter / 1e18);
		//console.log("gasUsed", gasUsed / 1e18);
		//console.log("change", (balancePrior - balanceAfter - gasUsed) / 1e18);
		
		await increaseTime(3700); // wait for oracle to be ready
		
		const data = await getMintCollateralETHUniV3Action(router, "0xEE5Ca68bae98c3e36BfbfEFFB104f22E4Ff34cf7", "6", "500", new BN("-240000"), new BN("-150001"), "322000000000000", "1000000", "0", "0", true, true);
		//const data = await getMintAndLeverageETHUniV3Action(router, "0xEE5Ca68bae98c3e36BfbfEFFB104f22E4Ff34cf7", MAX_UINT_256, "500", new BN("-240000"), new BN("-150000"), "322000000000000", "1000000","644000000000000", "2000000", "0", "0", true, true);
		//const data = await getDeleverageETHUniV3Action(router, "0xeD204BdC73C409378d6E0560caf004e78eB65ed3", "0xEE5Ca68bae98c3e36BfbfEFFB104f22E4Ff34cf7", bnMantissa(1), "0","0", true, true);
		//const data = await getMintCollateralETHUniV3Action(router, "0xEE5Ca68bae98c3e36BfbfEFFB104f22E4Ff34cf7", "0", "500", new BN("-199621"), new BN("-191621"), "1000000000000000", "3000000", "500000000000000", "1500000", true, true);
		//const data = await getMintAndLeverageETHUniV3Action(router, "0xEE5Ca68bae98c3e36BfbfEFFB104f22E4Ff34cf7", "0", "500", new BN("-199621"), new BN("-191621"), "1000000000000000", "3000000", "2000000000000000", "6000000", "1000000000000000", "3000000", true, true);
		console.log(data);
	});
	
});