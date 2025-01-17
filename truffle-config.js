module.exports = {
	networks: {
		development: {
			host: "127.0.0.1",	
			port: 8545,		
			network_id: "*",
			gasPrice: 106997207339,
		},
	},
	compilers: {
		solc: {
			version: "0.5.16",
			settings: {
				optimizer: {
					enabled: true,
					runs: 999999
				},
			},
		},
	},
};
