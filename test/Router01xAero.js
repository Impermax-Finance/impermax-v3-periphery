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
	encodePermits,
	routerManager,
	mintCollateralETHAero,
	redeemCollateralETHAero,
	mintAndLeverageETHAero,
	deleverageETHAero,
	//getMintCollateralETHUniV3Action,
	//getMintAndLeverageETHUniV3Action,
	//getDeleverageETHUniV3Action,
} = require('./Utils/ImpermaxPeriphery');
const {
	permitGenerator,
	PERMIT2_ADDRESS,
} = require('./Utils/PermitHelper');
const { keccak256, toUtf8Bytes } = require('ethers/utils');

const IERC20 = artifacts.require('IERC20');
const IWETH = artifacts.require('IWETH');
const IAeroRouter = artifacts.require('IAeroRouter');
const ICLFactory = artifacts.require('ICLFactory');
const ICLGaugeAero = artifacts.require('ICLGaugeAero');
const Factory = artifacts.require('ImpermaxV3Factory');
const BDeployer = artifacts.require('BDeployer');
const CDeployer = artifacts.require('CDeployer');
const Collateral = artifacts.require('ImpermaxV3Collateral');
const Borrowable = artifacts.require('ImpermaxV3Borrowable');
const IUniswapV3Pool = artifacts.require('IUniswapV3Pool');
const INonfungiblePositionManagerAero = artifacts.require('INonfungiblePositionManagerAero');
const NfpmAeroInteractions = artifacts.require('NfpmAeroInteractions');
const TokenizedAeroCLDeployer = artifacts.require('TokenizedAeroCLDeployer');
const TokenizedAeroCLFactory = artifacts.require('TokenizedAeroCLFactory');
const TokenizedAeroCLPosition = artifacts.require('TokenizedAeroCLPosition');
const ImpermaxV3OracleChainlink = artifacts.require('ImpermaxV3OracleChainlink');
const NextAeroIdGetter = artifacts.require('NextAeroIdGetter');
const VaultFactory = artifacts.require('ILendingVaultV2Factory');

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
const NO_PERMITS = encodePermits([]);

// FORK BASE IN ORDER TO RUN THIS

contract('ImpermaxV3AeroRouter01', function (accounts) {
	let root = accounts[0];
	let borrower = accounts[1];
	let lender = accounts[2];
	
	
	it('do', async () => {
		const WETH = await IERC20.at("0x4200000000000000000000000000000000000006");
		const WETHwrap = await IWETH.at("0x4200000000000000000000000000000000000006");
		const USDC = await IERC20.at("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913");
		const AERO = await IERC20.at("0x940181a94a35a4569e4529a3cdfb74e38fd98631");
		const nfpm = await INonfungiblePositionManagerAero.at("0x827922686190790b37229fd06084350E74485b72");
		const clPool = await IUniswapV3Pool.at("0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59");
		const gauge = await ICLGaugeAero.at("0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8");
		const aeroRouter = await IAeroRouter.at("0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43");
		const aeroFactory = await ICLFactory.at("0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A");
		const oracle = await ImpermaxV3OracleChainlink.at("0x6799246165c8ce1ed2e5cf8c494fa8e7a5de4472");
		const impermaxFactory = await Factory.at("0x870FD2C2B502db53d3c9E19aB99725c1129fC120");
		const vaultFactory = await VaultFactory.at("0x77Fb0Ff573Da1eC6EC0Cadb31A8Cf69A4BDd9C8D");
		const swapRouterAddress = "0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5";
		
		const TICK_SPACING = 100;
		const priceA = -250000;
		const priceB = -100000;
		
		const route = {
			from: WETH.address,
			to: USDC.address,
			stable: false,
			factory: "0x420DD381b31aEf6683db6B902084cB0FFECe40Da"
		};
		await aeroRouter.swapExactETHForTokens(0, [route], root, '20000000000000000000', {from: root, value: bnMantissa(20)});
		
		const nfpmAeroInteractions = await NfpmAeroInteractions.new();
		await TokenizedAeroCLDeployer.link(nfpmAeroInteractions);
		const tokenizedAeroCLDeployer = await TokenizedAeroCLDeployer.new();
		const tokenizedAeroCLFactory = await TokenizedAeroCLFactory.new(
			root, 
			aeroFactory.address, 
			nfpm.address, 
			tokenizedAeroCLDeployer.address, 
			oracle.address, 
			AERO.address
		);
		
		const nftlpAddress = await tokenizedAeroCLFactory.createNFTLP.call(WETH.address, USDC.address);
		await tokenizedAeroCLFactory.createNFTLP(WETH.address, USDC.address);
		const nftlp = await TokenizedAeroCLPosition.at(nftlpAddress);
		await nftlp._addGauge(TICK_SPACING, gauge.address);
		
		const collateralAddress = await impermaxFactory.createCollateral.call(nftlpAddress);
		const borrowable0Address = await impermaxFactory.createBorrowable0.call(nftlpAddress);
		const borrowable1Address = await impermaxFactory.createBorrowable1.call(nftlpAddress);
		await impermaxFactory.createCollateral(nftlpAddress);
		await impermaxFactory.createBorrowable0(nftlpAddress);
		await impermaxFactory.createBorrowable1(nftlpAddress);
		await impermaxFactory.initializeLendingPool(nftlpAddress);
		const collateral = await Collateral.at(collateralAddress);
		const borrowable0 = await Borrowable.at(borrowable0Address);
		const borrowable1 = await Borrowable.at(borrowable1Address);
		const ETH_IS_0 = await borrowable0.underlying() == WETH.address;
		
		const [borrowableWETH, borrowableUSDC] = ETH_IS_0 ? [borrowable0, borrowable1] : [borrowable1, borrowable0];
		//await increaseTime(3700); // wait for oracle to be ready
		await permitGenerator.initialize();
		
		const nextAeroIdGetter = await NextAeroIdGetter.new(nfpm.address, WETH.address, USDC.address);
		await WETHwrap.deposit({value: bnMantissa(0.001)});
		await WETH.transferFrom(root, nextAeroIdGetter.address, bnMantissa(0.001), {from: root});
		
		// deploy routers
		await routerManager.initialize();
		await routerManager.initializePoolToken(WETH.address);
		await routerManager.initializeAero(impermaxFactory.address, tokenizedAeroCLFactory.address, WETH.address, vaultFactory.address, nextAeroIdGetter.address, swapRouterAddress);
		const router = routerManager.aero;
		const routerLend = routerManager.poolToken;
		

		const ETH_LP_AMOUNT = bnMantissa(4);
		const ETH_BORROW_AMOUNT = bnMantissa(6);
		const USDC_LP_AMOUNT = 26000 * 1e6;
		const USDC_BORROW_AMOUNT = 10000 * 1e6;
		
		await routerLend.mintETH(borrowable0.address, root, {from: root, value: ETH_BORROW_AMOUNT});
		await routerLend.mintETH(borrowable0.address, root, {from: root, value: ETH_BORROW_AMOUNT});
		await USDC.approve(routerLend.address, USDC_BORROW_AMOUNT * 2, {from: root});		
		await routerLend.mint(borrowable1.address, USDC_BORROW_AMOUNT * 2, root, NO_PERMITS, {from: root});
		
		console.log("eth balance", await web3.eth.getBalance(root) / 1e18);
		console.log("usdc balance", await USDC.balanceOf(root) / 1e6);
		console.log("aero balance", await AERO.balanceOf(root) / 1e18);
				
		/* TEST 1 
		await USDC.approve(router.address, USDC_LP_AMOUNT, {from: root});
		const receipt = await mintCollateralETHAero(router, nftlp, root, MAX_UINT_256, TICK_SPACING, new BN(priceA), new BN(priceB), ETH_LP_AMOUNT, USDC_LP_AMOUNT, bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		const tokenId = receipt.tokenId;
		
		console.log("eth balance", await web3.eth.getBalance(root) / 1e18);
		console.log("usdc balance", await USDC.balanceOf(root) / 1e6);
		
		await USDC.approve(router.address, USDC_LP_AMOUNT, {from: root});
		await mintCollateralETHAero(router, nftlp, root, tokenId, 0, 0, 0, ETH_LP_AMOUNT, USDC_LP_AMOUNT, bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		
		console.log("eth balance", await web3.eth.getBalance(root) / 1e18);
		console.log("usdc balance", await USDC.balanceOf(root) / 1e6);
		
		await increaseTime(3700); 
		await nftlp.claim(root, tokenId);
		console.log("aero balance", await AERO.balanceOf(root) / 1e18);
		
		await collateral.approve(router.address, tokenId, {from: root});
		await redeemCollateralETHAero(router, nftlp, root, tokenId, bnMantissa(0.3), bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		
		console.log("eth balance", await web3.eth.getBalance(root) / 1e18);
		console.log("usdc balance", await USDC.balanceOf(root) / 1e6);
		
		await increaseTime(3700); 
		await collateral.approve(router.address, tokenId, {from: root});
		await redeemCollateralETHAero(router, nftlp, root, tokenId, bnMantissa(1), bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		*/
		
		/* TEST 2 */
		await USDC.approve(router.address, USDC_LP_AMOUNT, {from: root});
		const receipt = await mintAndLeverageETHAero(router, nftlp, root, MAX_UINT_256, TICK_SPACING, new BN(priceA), new BN(priceB), ETH_LP_AMOUNT, USDC_LP_AMOUNT, ETH_LP_AMOUNT.add(ETH_BORROW_AMOUNT), USDC_LP_AMOUNT + USDC_BORROW_AMOUNT, bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		const tokenId = receipt.tokenId;
		
		console.log("eth balance", await web3.eth.getBalance(root) / 1e18);
		console.log("usdc balance", await USDC.balanceOf(root) / 1e6);
		console.log("eth borrowed", await borrowable0.borrowBalance(tokenId) / 1e18);
		console.log("usdc borrowed", await borrowable1.borrowBalance(tokenId) / 1e6);
		
		await collateral.approve(router.address, tokenId, {from: root});
		await mintAndLeverageETHAero(router, nftlp, root, tokenId, 0, 0, 0, 0, 0, ETH_BORROW_AMOUNT, USDC_BORROW_AMOUNT, bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		
		console.log("eth borrowed", await borrowable0.borrowBalance(tokenId) / 1e18);
		console.log("usdc borrowed", await borrowable1.borrowBalance(tokenId) / 1e6);
		
		await increaseTime(3700); 
		await nftlp.claim(root, tokenId);
		console.log("aero balance", await AERO.balanceOf(root) / 1e18);
		
		await collateral.approve(router.address, tokenId, {from: root});
		await deleverageETHAero(router, nftlp, root, tokenId, bnMantissa(0.1), bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		
		console.log("eth balance", await web3.eth.getBalance(root) / 1e18);
		console.log("usdc balance", await USDC.balanceOf(root) / 1e6);
		console.log("eth borrowed", await borrowable0.borrowBalance(tokenId) / 1e18);
		console.log("usdc borrowed", await borrowable1.borrowBalance(tokenId) / 1e6);
		
		await increaseTime(3700); 
		await collateral.approve(router.address, tokenId, {from: root});
		await deleverageETHAero(router, nftlp, root, tokenId, bnMantissa(1), bnMantissa(0), bnMantissa(0), ETH_IS_0, ETH_IS_0);
		
		console.log("eth balance", await web3.eth.getBalance(root) / 1e18);
		console.log("usdc balance", await USDC.balanceOf(root) / 1e6);
		console.log("aero balance", await AERO.balanceOf(root) / 1e18);
		console.log("eth borrowed", await borrowable0.borrowBalance(tokenId) / 1e18);
		console.log("usdc borrowed", await borrowable1.borrowBalance(tokenId) / 1e6);
		
	});
	
});