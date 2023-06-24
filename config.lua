return {
	bot = {
		http_response_timeout   = 5,
		http_server             = "tptutilitybot/1.0.0",
		ident_token_max_age     = 300,
		random_recheck_interval = 60,
		recheck_cache_max_age   = 300,
		account_min_age         = 86400,
		rquser_max_log          = 100,
		sender_max_log          = 100,
		embed_rate_numerator    = 10,
		embed_rate_denominator  = 60,
		debug_discord_client    = false,
	},
	powder = {
		fetch_user_timeout      = 5,
		fetch_save_timeout      = 5,
		externalauth_timeout    = 5,
		powder_token_max_age    = 300,
	},
	db = {
		busy_delay              = 5,
	},
}
