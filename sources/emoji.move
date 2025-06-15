#[allow(unused_variable, lint(share_owned))]

module emoji::core {
    use std::string::{Self, String};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::vec_map::{Self, VecMap};

    // Error codes - not sure if these numbers are right but they work
    const EEmojiExists: u64 = 1;
    const EInvalidAmount: u64 = 2;
    const ESlippage: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EInsufficientReserves: u64 = 5;
    //const ECoinNotFound: u64 = 6; // unnused for now 
    const EInvalidEmoji: u64 = 7;
    //const EMetadataNotFound: u64 = 8; // commented out for now

    // Constants - copied these values from a tutorial
    const CREATION_FEE: u64 = 100_000_000; // 0.1 SUI 
    const INITIAL_TOKEN_RESERVE: u64 = 1_000_000_000_000_000_000; //  1B tokens
    const DECIMALS: u8 = 9;

    // Custom metadata struct - this was tricky to figure out
    // Trying to store emoji metadata since Sui's default doesn't support unicode properly
    public struct EmojiMetadata has key, store {
        id: UID,
        symbol: String,        // This should hold the actual emoji
        name: String,          // Full name like "Rocket to the Moon"
        description: String,   // Description text
        icon_url: String,      // URL for the icon
        website: Option<String>, // Optional website link
        twitter: Option<String>, // Optional twitter handle
        telegram: Option<String>, // Optional telegram link
        tags: vector<String>,  // Array of tags
        creator_message: String, // Message from whoever created it
        launch_date: u64,      // When it was created
        total_holders: u64,    // How many people own it
        community_votes: u64,  // Community voting stuff
        verified: bool,        // Is this verified or not
        attributes: VecMap<String, String>, // Extra key-value pairs
    }

    // Global registry for metadata - need this to track everything
    public struct MetadataRegistry has key {
        id: UID,
        metadata_map: Table<ID, ID>, // maps coin id to metadata id
        emoji_metadata: Table<String, ID>, // maps emoji to metadata id
        total_registered: u64,
    }

    // Registry for all coins - keeps track of created coins
    public struct EmojiRegistry has key {
        id: UID,
        coins: Table<String, ID>, // emoji string maps to coin object id
        total_created: u64,
    }

    // Main coin struct - tried to keep this simple
    public struct EmojiCoin<phantom T> has key {
        id: UID,
        emoji: String, // Store emoji here for quick access
        creator: address,
        treasury: TreasuryCap<T>, // For minting and burning
        // Bonding curve stuff - still learning how this works
        sui_reserve: Balance<SUI>,
        token_reserve: u64,
        volume_24h: u64, // 24 hour trading volume
        created_at: u64,
        total_supply: u64,
        metadata_id: ID, // Points to the metadata object
    }

    // For tracking user balances - not sure if this is the best way
    public struct TokenBalance<phantom T> has key, store {
        id: UID,
        emoji: String,
        balance: Balance<T>,
        owner: address,
    }

    // One-time witness pattern - copied from documentation
    public struct EMOJI_COIN has drop {}

    // Events - these get emitted when stuff happens
    public struct CoinCreated has copy, drop {
        emoji: String,
        creator: address,
        coin_id: ID,
        metadata_id: ID,
        symbol: String,
        name: String,
        timestamp: u64,
    }

    public struct MetadataUpdated has copy, drop {
        metadata_id: ID,
        coin_id: ID,
        emoji: String,
        updater: address,
        field_updated: String,
    }

    public struct Trade has copy, drop {
        emoji: String,
        coin_id: ID,
        trader: address,
        is_buy: bool,
        sui_amount: u64,
        token_amount: u64,
        new_price: u64,
    }

    // Initialize the module - this runs when the module is published
    fun init(ctx: &mut TxContext) {
        // Create the coin registry
        let registry = EmojiRegistry {
            id: object::new(ctx),
            coins: table::new(ctx),
            total_created: 0,
        };
        
        // Create the metadata registry
        let metadata_registry = MetadataRegistry {
            id: object::new(ctx),
            metadata_map: table::new(ctx),
            emoji_metadata: table::new(ctx),
            total_registered: 0,
        };
        
        // Make these shared objects so everyone can access them
        transfer::share_object(registry);
        transfer::share_object(metadata_registry);
    }

    // Create custom metadata - this handles unicode emojis
    public fun create_emoji_metadata(
        emoji: String,
        name: String,
        description: String,
        icon_url: String,
        website: Option<String>,
        twitter: Option<String>,
        telegram: Option<String>,
        tags: vector<String>,
        creator_message: String,
        clock: &Clock,
        ctx: &mut TxContext
    ): EmojiMetadata {
        // Build the metadata object
        let metadata = EmojiMetadata {
            id: object::new(ctx),
            symbol: emoji,
            name,
            description,
            icon_url,
            website,
            twitter,
            telegram,
            tags,
            creator_message,
            launch_date: clock::timestamp_ms(clock),
            total_holders: 0,
            community_votes: 0,
            verified: false,
            attributes: vec_map::empty(),
        };
        
        metadata
    }

    // Create a new emoji coin - this is the main function
    // Takes a lot of parameters but need all this info
    public fun create_emoji_coin_with_metadata(
        registry: &mut EmojiRegistry,
        metadata_registry: &mut MetadataRegistry,
        emoji: String,
        name: String,
        description: String,
        icon_url: String,
        website: Option<String>,
        twitter: Option<String>,
        telegram: Option<String>,
        tags: vector<String>,
        creator_message: String,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ): ID {
        // Check if emoji already exists
        assert!(!table::contains(&registry.coins, emoji), EEmojiExists);
        assert!(coin::value(&payment) >= CREATION_FEE, EInvalidAmount);
        assert!(is_valid_emoji(&emoji), EInvalidEmoji);
        
        let creator = tx_context::sender(ctx);
        let timestamp = clock::timestamp_ms(clock);
        
        // Create the custom metadata first
        let metadata = create_emoji_metadata(
            emoji,
            name,
            description,
            icon_url,
            website,
            twitter,
            telegram,
            tags,
            creator_message,
            clock,
            ctx
        );
        
        let metadata_id = object::uid_to_inner(&metadata.id);
        
        // Create the coin treasury - using dummy values because Sui's coin metadata is ascii only
        // We'll use our custom metadata instead
        let (treasury, _dummy_metadata) = coin::create_currency(
            EMOJI_COIN {},
            DECIMALS,
            b"EMOJI", // Just a placeholder
            b"EmojiCoin", // Just a placeholder
            b"Custom emoji token", // Just a placeholder
            option::none(),
            ctx
        );
        
        // Freeze the dummy metadata since we're not using it
        transfer::public_freeze_object(_dummy_metadata);
        
        // Create the actual coin object
        let coin_obj = EmojiCoin {
            id: object::new(ctx),
            emoji,
            creator,
            treasury,
            sui_reserve: coin::into_balance(payment), // Put the creation fee into reserves
            token_reserve: INITIAL_TOKEN_RESERVE,
            volume_24h: 0,
            created_at: timestamp,
            total_supply: 0,
            metadata_id,
        };
        
        let coin_id = object::uid_to_inner(&coin_obj.id);
        
        // Add to registries
        table::add(&mut registry.coins, emoji, coin_id);
        table::add(&mut metadata_registry.metadata_map, coin_id, metadata_id);
        table::add(&mut metadata_registry.emoji_metadata, emoji, metadata_id);
        
        // Update counters
        registry.total_created = registry.total_created + 1;
        metadata_registry.total_registered = metadata_registry.total_registered + 1;
        
        // Emit event
        event::emit(CoinCreated { 
            emoji, 
            creator, 
            coin_id,
            metadata_id,
            symbol: emoji,
            name: metadata.name,
            timestamp 
        });
        
        // Make objects shared
        transfer::share_object(metadata);
        transfer::share_object(coin_obj);
        
        metadata_id
    }

    // Entry function for creating coins - this is what users call
    public entry fun create_coin_entry(
        registry: &mut EmojiRegistry,
        metadata_registry: &mut MetadataRegistry,
        emoji: String,
        name: String,
        description: String,
        icon_url: String,
        website: String,
        twitter: String,
        telegram: String,
        creator_message: String,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Convert empty strings to None - not sure if this is the best way
        let website_opt = if (string::is_empty(&website)) { 
            option::none() 
        } else { 
            option::some(website) 
        };
        
        let twitter_opt = if (string::is_empty(&twitter)) { 
            option::none() 
        } else { 
            option::some(twitter) 
        };
        
        let telegram_opt = if (string::is_empty(&telegram)) { 
            option::none() 
        } else { 
            option::some(telegram) 
        };
        
        // Create some default tags
        let mut tags = vector::empty<String>();
        vector::push_back(&mut tags, string::utf8(b"emoji"));
        vector::push_back(&mut tags, emoji);
        
        // Call the main function
        let _metadata_id = create_emoji_coin_with_metadata(
            registry,
            metadata_registry,
            emoji,
            name,
            description,
            icon_url,
            website_opt,
            twitter_opt,
            telegram_opt,
            tags,
            creator_message,
            payment,
            clock,
            ctx
        );
    }

    // Get metadata by coin ID
    public fun get_metadata_by_coin_id(
        metadata_registry: &MetadataRegistry,
        coin_id: ID
    ): Option<ID> {
        if (table::contains(&metadata_registry.metadata_map, coin_id)) {
            option::some(*table::borrow(&metadata_registry.metadata_map, coin_id))
        } else {
            option::none()
        }
    }

    // Get metadata by emoji string
    public fun get_metadata_by_emoji(
        metadata_registry: &MetadataRegistry,
        emoji: String
    ): Option<ID> {
        if (table::contains(&metadata_registry.emoji_metadata, emoji)) {
            option::some(*table::borrow(&metadata_registry.emoji_metadata, emoji))
        } else {
            option::none()
        }
    }

    // Get all the metadata info - returns a tuple with all the fields
    public fun get_metadata_info(metadata: &EmojiMetadata): (
        String, // symbol
        String, // name
        String, // description
        String, // icon_url
        Option<String>, // website
        Option<String>, // twitter
        Option<String>, // telegram
        vector<String>, // tags
        String, // creator_message
        u64,    // launch_date
        bool    // verified
    ) {
        (
            metadata.symbol,
            metadata.name,
            metadata.description,
            metadata.icon_url,
            metadata.website,
            metadata.twitter,
            metadata.telegram,
            metadata.tags,
            metadata.creator_message,
            metadata.launch_date,
            metadata.verified
        )
    }

    // Update metadata description - only allows changing description for now
    public entry fun update_metadata_description(
        metadata: &mut EmojiMetadata,
        new_description: String,
        ctx: &mut TxContext
    ) {
        metadata.description = new_description;
        
        // Emit event
        event::emit(MetadataUpdated {
            metadata_id: object::uid_to_inner(&metadata.id),
            coin_id: object::uid_to_inner(&metadata.id), // TODO: fix this
            emoji: metadata.symbol,
            updater: tx_context::sender(ctx),
            field_updated: string::utf8(b"description"),
        });
    }

    // Add custom attribute to metadata
    public entry fun add_metadata_attribute(
        metadata: &mut EmojiMetadata,
        key: String,
        value: String,
        ctx: &mut TxContext
    ) {
        // Remove existing key if it exists
        if (vec_map::contains(&metadata.attributes, &key)) {
            let (_, _) = vec_map::remove(&mut metadata.attributes, &key);
        };
        vec_map::insert(&mut metadata.attributes, key, value);
        
        // Emit event
        event::emit(MetadataUpdated {
            metadata_id: object::uid_to_inner(&metadata.id),
            coin_id: object::uid_to_inner(&metadata.id),
            emoji: metadata.symbol,
            updater: tx_context::sender(ctx),
            field_updated: string::utf8(b"custom_attribute"),
        });
    }

    // Get custom attribute from metadata
    public fun get_metadata_attribute(
        metadata: &EmojiMetadata,
        key: &String
    ): Option<String> {
        if (vec_map::contains(&metadata.attributes, key)) {
            option::some(*vec_map::get(&metadata.attributes, key))
        } else {
            option::none()
        }
    }

    // Buy tokens - this implements the bonding curve
    public entry fun buy(
        coin_obj: &mut EmojiCoin<EMOJI_COIN>,
        payment: Coin<SUI>,
        min_tokens: u64,
        ctx: &mut TxContext
    ) {
        let sui_amount = coin::value(&payment);
        assert!(sui_amount > 0, EInvalidAmount);
        
        // Calculate how many tokens to give
        let tokens_out = get_buy_amount(coin_obj, sui_amount);
        assert!(tokens_out >= min_tokens, ESlippage);
        assert!(tokens_out <= coin_obj.token_reserve, EInsufficientReserves);
        
        // Update the reserves
        balance::join(&mut coin_obj.sui_reserve, coin::into_balance(payment));
        coin_obj.token_reserve = coin_obj.token_reserve - tokens_out;
        coin_obj.total_supply = coin_obj.total_supply + tokens_out;
        coin_obj.volume_24h = coin_obj.volume_24h + sui_amount;
        
        let trader = tx_context::sender(ctx);
        
        // Mint the tokens
        let minted_coins = coin::mint(&mut coin_obj.treasury, tokens_out, ctx);
        let token_balance = TokenBalance {
            id: object::new(ctx),
            emoji: coin_obj.emoji,
            balance: coin::into_balance(minted_coins),
            owner: trader,
        };
        
        // Emit trade event
        event::emit(Trade {
            emoji: coin_obj.emoji,
            coin_id: object::uid_to_inner(&coin_obj.id),
            trader,
            is_buy: true,
            sui_amount,
            token_amount: tokens_out,
            new_price: get_current_price(coin_obj),
        });
        
        // Send tokens to buyer
        transfer::transfer(token_balance, trader);
    }

    // Sell tokens - reverse of buy
    public entry fun sell(
        coin_obj: &mut EmojiCoin<EMOJI_COIN>,
        token_balance: TokenBalance<EMOJI_COIN>,
        min_sui: u64,
        ctx: &mut TxContext
    ) {
        // Unpack the token balance
        let TokenBalance { id, emoji: _, balance: token_bal, owner } = token_balance;
        object::delete(id);
        
        // Make sure the seller owns the tokens
        assert!(owner == tx_context::sender(ctx), EUnauthorized);
        
        let token_amount = balance::value(&token_bal);
        let sui_out = get_sell_amount(coin_obj, token_amount);
        assert!(sui_out >= min_sui, ESlippage);
        assert!(sui_out <= balance::value(&coin_obj.sui_reserve), EInsufficientReserves);
        
        // Update reserves
        let sui_balance = balance::split(&mut coin_obj.sui_reserve, sui_out);
        coin_obj.token_reserve = coin_obj.token_reserve + token_amount;
        coin_obj.total_supply = coin_obj.total_supply - token_amount;
        coin_obj.volume_24h = coin_obj.volume_24h + sui_out;
        
        let trader = tx_context::sender(ctx);
        
        // Burn the tokens
        let coins_to_burn = coin::from_balance(token_bal, ctx);
        coin::burn(&mut coin_obj.treasury, coins_to_burn);
        
        // Emit trade event
        event::emit(Trade {
            emoji: coin_obj.emoji,
            coin_id: object::uid_to_inner(&coin_obj.id),
            trader,
            is_buy: false,
            sui_amount: sui_out,
            token_amount,
            new_price: get_current_price(coin_obj),
        });
        
        // Send SUI to seller
        transfer::public_transfer(coin::from_balance(sui_balance, ctx), trader);
    }

    // Calculate how many tokens you get for buying with SUI
    // This is the bonding curve math - still trying to understand it fully
    public fun get_buy_amount(coin_obj: &EmojiCoin<EMOJI_COIN>, sui_amount: u64): u64 {
        let sui_reserve = balance::value(&coin_obj.sui_reserve);
        let token_reserve = coin_obj.token_reserve;
        
        if (sui_reserve == 0 || token_reserve == 0) return 0;
        
        // Apply 0.3% fee
        let sui_amount_after_fee = sui_amount * 997 / 1000;
        let new_sui_reserve = sui_reserve + sui_amount_after_fee;
        let new_token_reserve = (sui_reserve * token_reserve) / new_sui_reserve;
        
        token_reserve - new_token_reserve
    }

    // Calculate how much SUI you get for selling tokens
    public fun get_sell_amount(coin_obj: &EmojiCoin<EMOJI_COIN>, token_amount: u64): u64 {
        let sui_reserve = balance::value(&coin_obj.sui_reserve);
        let token_reserve = coin_obj.token_reserve;
        
        if (sui_reserve == 0 || token_reserve == 0) return 0;
        
        let new_token_reserve = token_reserve + token_amount;
        let new_sui_reserve = (sui_reserve * token_reserve) / new_token_reserve;
        let sui_out = sui_reserve - new_sui_reserve;
        
        // Apply 0.3% fee
        sui_out * 997 / 1000
    }

    // Get current price per token
    public fun get_current_price(coin_obj: &EmojiCoin<EMOJI_COIN>): u64 {
        let sui_reserve = balance::value(&coin_obj.sui_reserve);
        let token_reserve = coin_obj.token_reserve;
        
        if (token_reserve == 0) return 0;
        // Multiply by 1M for precision
        (sui_reserve * 1_000_000) / token_reserve
    }

    // Get basic stats about a coin
    public fun get_coin_stats(coin_obj: &EmojiCoin<EMOJI_COIN>): (String, address, u64, u64, u64, ID) {
        (
            coin_obj.emoji,
            coin_obj.creator,
            coin_obj.volume_24h,
            get_current_price(coin_obj),
            coin_obj.total_supply,
            coin_obj.metadata_id
        )
    }

    // Check if a string is a valid emoji - basic validation
    public fun is_valid_emoji(emoji: &String): bool {
        let emoji_bytes = string::as_bytes(emoji);
        let len = vector::length(emoji_bytes);
        
        // Basic checks
        if (len == 0 || len > 20) return false;
        
        // Check first byte to see if it looks like unicode
        if (len > 0) {
            let first_byte = *vector::borrow(emoji_bytes, 0);
            // This is a simple check, might need to improve
            first_byte == 0xF0 || first_byte == 0xE2 || first_byte < 0x80
        } else {
            false
        }
    }

    // Test functions - only compiled in test mode
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun test_custom_metadata_system(ctx: &mut TxContext) {
        init(ctx);
        
        // Test basic functionality
        let emoji = string::utf8(b"🚀");
        let name = string::utf8(b"Rocket Coin");
        let description = string::utf8(b"A rocket themed coin");
        
        assert!(is_valid_emoji(&emoji), 0);
        // Should work with unicode emojis
    }
}