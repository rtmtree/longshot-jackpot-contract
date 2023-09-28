/*
*/

module rtmtree::foot_penalty_jackpot {
    use std::signer;
    // use std::vector;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::aptos_coin::{ AptosCoin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account::{Self, SignerCapability};

    #[test_only]
    use aptos_framework::aptos_coin::{Self};


    //////////////
    // ERRORS ////
    //////////////

    const ESIGNER_NOT_ADMIN: u64 = 0;
    const EPLAYER_HAS_NOT_JOINED: u64 = 1;
    const EDEADLINE_HAS_PASSED: u64 = 2;
    const EDEADLINE_HAS_NOT_PASSED: u64 = 3;
    const EINSUFFICIENT_BALANCE: u64 = 4;

    ////////////
    // Seed ////
    ////////////

    const SEED: vector<u8> = b"RTMTREE_LONGSHOT_JACKPOT";

    /////////////////
    // CONSTANTS ////
    /////////////////

    const SHOOT_DURATION : u64 = 2 * 60; // 2 minutes

    /////////////
    // STRUCTS //
    /////////////

    /*
        Resource kept under resource address.
    */
    struct State has key {
        // SingerCapability
        sign_cap: SignerCapability,
        // shoot deadline mapper
        shoot_deadline_mapper: SimpleMap<address, u64>,
        // ticket price
        ticket_price: u64,
        // reward percentage
        reward_percentage: u64,
        // admin percentage
        admin_percentage: u64,
        // Events
        event_handlers: EventHandlers
    }

    /*
        Holds data about event handlers
    */
    struct EventHandlers has store {
        shoot_events: EventHandle<ShootEvent>,
        goal_shot_events: EventHandle<GoalShotEvent>,
        ticket_price_update_events: EventHandle<TicketPriceUpdateEvent>,
    }

    ////////////
    // EVENTS //
    ////////////

    struct ShootEvent has store, drop {
        player: address,
        shoot_deadline: u64,
        timestamp: u64
    }
    struct GoalShotEvent has store, drop {
        player: address,
        reward: u64,
        timestamp: u64
    }
    struct TicketPriceUpdateEvent has store, drop {
        old_ticket_price: u64,
        new_ticket_price: u64,
        timestamp: u64
    }

    ///////////////
    // FUNCTIONS //
    ///////////////

    fun init_module(admin: &signer) {
        // Assert the signer is the admin
        assert_signer_is_admin(admin);

        // Create resource account
        let (resource_signer, sign_cap) = account::create_resource_account(admin, SEED);

        // Register AptosCoin to resource
        coin::register<AptosCoin>(&resource_signer);

        // Create State instance and move it to the resource account
        let instance = State {
            sign_cap: move sign_cap,
            ticket_price: 0,
            reward_percentage: 80,
            admin_percentage: 4,
            shoot_deadline_mapper: simple_map::create(),
            event_handlers: EventHandlers {
                shoot_events: account::new_event_handle<ShootEvent>(&resource_signer),
                goal_shot_events: account::new_event_handle<GoalShotEvent>(&resource_signer),
                ticket_price_update_events: account::new_event_handle<TicketPriceUpdateEvent>(&resource_signer),
            }
        };
        move_to<State>(&move resource_signer,move instance);
    }

    public entry fun set_ticket_price(
        admin: &signer,
        ticket_price: u64,
    ) acquires State {
        assert_signer_is_admin(admin);

        let resource_account_address = get_resource_account_address();
        let state = borrow_global_mut<State>(resource_account_address);
        let old_ticket_price = state.ticket_price;
        state.ticket_price = ticket_price;
        
        event::emit_event<TicketPriceUpdateEvent>(
            &mut state.event_handlers.ticket_price_update_events,
            TicketPriceUpdateEvent {
                old_ticket_price,
                new_ticket_price: move ticket_price,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    public entry fun set_reward_percentage(
        admin: &signer,
        reward_percentage: u64,
    ) acquires State {
        assert_signer_is_admin(admin);

        let resource_account_address = get_resource_account_address();
        let state = borrow_global_mut<State>(resource_account_address);
        state.reward_percentage = move reward_percentage;
    }

    public entry fun set_admin_percentage(
        admin: &signer,
        admin_percentage: u64,
    ) acquires State {
        assert_signer_is_admin(admin);

        let resource_account_address = get_resource_account_address();
        let state = borrow_global_mut<State>(resource_account_address);
        state.admin_percentage = move admin_percentage;
    }

    public entry fun shoot(
        player: &signer,
    ) acquires State {
        let resource_account_address = get_resource_account_address();
        let state = borrow_global_mut<State>(resource_account_address);

        // Check if the player is already joined
        if (simple_map::contains_key(&state.shoot_deadline_mapper, &signer::address_of(player))){
            // Assert that the last shoot deadline is passed
            assert!( *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(player)) < timestamp::now_seconds(), EDEADLINE_HAS_NOT_PASSED);
        };

        // Transfer ticket price to the resource account
        let ticket_price = state.ticket_price;
        if (ticket_price > 0){
            assert!(coin::balance<AptosCoin>(signer::address_of(player)) >= ticket_price, EINSUFFICIENT_BALANCE);
            coin::transfer<AptosCoin>(player, resource_account_address, ticket_price);
        };  

        // Set the shoot deadline for this player
        let shoot_deadline = timestamp::now_seconds() + SHOOT_DURATION;
        simple_map::upsert(&mut state.shoot_deadline_mapper, signer::address_of(player), shoot_deadline);

        // Emit ShootEvent event
        event::emit_event<ShootEvent>(
            &mut state.event_handlers.shoot_events,
            ShootEvent {
                player: signer::address_of(player),
                shoot_deadline: timestamp::now_seconds() + SHOOT_DURATION,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    public entry fun goal_shot(
        admin: &signer,
        player: address,
    ) acquires State {
        assert_signer_is_admin(admin);

        let resource_account_address = get_resource_account_address();
        let state = borrow_global_mut<State>(resource_account_address);

        // Assert that player joined the game
        assert!(simple_map::contains_key(&state.shoot_deadline_mapper, &player), EPLAYER_HAS_NOT_JOINED);

        // Assert that the shoot deadline is not passed
        assert!(*simple_map::borrow(&state.shoot_deadline_mapper, &player) > timestamp::now_seconds(), EDEADLINE_HAS_PASSED);

        // Get how much reward the player should get
        let reward = coin::balance<AptosCoin>(resource_account_address) * state.reward_percentage / 100;
        let admin_reward = coin::balance<AptosCoin>(resource_account_address) * state.admin_percentage / 100;

        // Transfer reward to the dev
        if (admin_reward > 0){
            let resource_signer = &account::create_signer_with_capability(&state.sign_cap);
            coin::transfer<AptosCoin>(resource_signer, @admin, admin_reward);
        };

        // Transfer reward if reward is more than 0
        if (reward > 0){
            let resource_signer = &account::create_signer_with_capability(&state.sign_cap);

            coin::transfer<AptosCoin>(resource_signer, player, reward);
            event::emit_event(
                &mut state.event_handlers.goal_shot_events,
                GoalShotEvent {
                    player: player,
                    reward: move reward,
                    timestamp: timestamp::now_seconds()
                }
            );
        };

    }

    /////////////
    // VIEWS ////
    /////////////

    #[view]
    /*
		Return the module's resource account 
		@return - the address of the module's resource account
    */  
    public inline fun get_resource_account_address(): address {
        let account_address = account::create_resource_address(&@admin, SEED);
        account_address
    }

    #[view]
    /*
        Return the ticket price
        @return - the ticket price
    */
    public inline fun get_ticket_price(): u64 {
        let resource_account_address = get_resource_account_address();
        let state = borrow_global<State>(resource_account_address);
        state.ticket_price
    }

    #[view]
    /*
        Return the reward percentage
        @return - the reward percentage
    */
    public inline fun get_reward_percentage(): u64 {
        let resource_account_address = get_resource_account_address();
        let state = borrow_global<State>(resource_account_address);
        state.reward_percentage
    }

    #[view]
    /*
        Return the admin percentage
        @return - the admin percentage
    */
    public inline fun get_admin_percentage(): u64 {
        let resource_account_address = get_resource_account_address();
        let state = borrow_global<State>(resource_account_address);
        state.admin_percentage
    }

    /////////////
    // ASSERTS //
    /////////////

    inline fun assert_signer_is_admin(admin: &signer) {
        // Assert that address of the parameter is the same as admin in Move.toml
        assert!(signer::address_of(move admin) == @admin, ESIGNER_NOT_ADMIN);
    }

    ////////////////////////////
    // TESTS ////
    ////////////////////////////


    #[test]
    fun test_init_module_success() acquires State {
        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let resource_account_address = get_resource_account_address();
        let state = borrow_global<State>(resource_account_address);

        assert!(state.ticket_price == 0, 0);
        assert!(state.reward_percentage == 80, 0);
        assert!(state.admin_percentage == 4, 0);

    }

    #[test]
    fun test_set_ticket_price_success() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 0, 0);

        set_ticket_price(&admin, 100);

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 100, 0);

        set_ticket_price(&admin, 20);

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 20, 0);

        assert!(event::counter(&state.event_handlers.ticket_price_update_events) == 2, 2);
    }

    #[test]
    fun test_set_reward_percentage_success() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.reward_percentage == 80, 0);

        set_reward_percentage(&admin, 100);

        let state = borrow_global<State>(resource_account_address);
        assert!(state.reward_percentage == 100, 0);

        set_reward_percentage(&admin, 30);

        let state = borrow_global<State>(resource_account_address);
        assert!(state.reward_percentage == 30, 0);
    }

    #[test]
    fun test_set_admin_percentage_success() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let resource_account_address = get_resource_account_address();
        let state = borrow_global<State>(resource_account_address);

        assert!(state.admin_percentage == 4, 0);

        set_admin_percentage(&admin, 100);

        let state = borrow_global<State>(resource_account_address);
        assert!(state.admin_percentage == 100, 0);

        set_admin_percentage(&admin, 30);

        let state = borrow_global<State>(resource_account_address);
        assert!(state.admin_percentage == 30, 0);

        set_admin_percentage(&admin, 40);

        let state = borrow_global<State>(resource_account_address);
        assert!(state.admin_percentage == 40, 0);

    }

    #[test]
    fun test_shoot_for_free_twice_success() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 0, 0);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        timestamp::fast_forward_seconds(SHOOT_DURATION + 1);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter(&state.event_handlers.shoot_events) == 2, 2);

    }

    #[test]
    #[expected_failure(abort_code = EDEADLINE_HAS_NOT_PASSED)]
    fun test_shoot_for_free_twice_failure_not_pass_deadline() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 0, 0);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        timestamp::fast_forward_seconds(SHOOT_DURATION / 2);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter(&state.event_handlers.shoot_events) == 2, 2);

    }

    #[test]
    fun test_shoot_1_apt_twice_success() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        
        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 0, 0);

        set_ticket_price(&admin, 100000000);
        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 100000000, 0);

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework_account);
        aptos_coin::mint(&aptos_framework_account, @0xCAFE, 100000000 * 2);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        assert!(coin::balance<AptosCoin>(signer::address_of(&player)) == 100000000 * 2, 0);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        timestamp::fast_forward_seconds(SHOOT_DURATION + 1);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter(&state.event_handlers.shoot_events) == 2, 0);

        assert!(coin::balance<AptosCoin>(resource_account_address) == 100000000 * 2, 0);
        assert!(coin::balance<AptosCoin>(signer::address_of(&player)) == 0, 0);
    }

    #[test]
    #[expected_failure(abort_code = EINSUFFICIENT_BALANCE)]
    fun test_shoot_1_apt_twice_failure_apt_not_enough() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        init_module(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        
        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 0, 0);

        set_ticket_price(&admin, 100000000);
        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 100000000, 0);

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework_account);
        aptos_coin::mint(&aptos_framework_account, @0xCAFE, 100000000);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        assert!(coin::balance<AptosCoin>(signer::address_of(&player)) == 100000000, 0);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        timestamp::fast_forward_seconds(SHOOT_DURATION + 1);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter(&state.event_handlers.shoot_events) == 2, 0);

        assert!(coin::balance<AptosCoin>(resource_account_address) == 100000000 * 2, 0);
        assert!(coin::balance<AptosCoin>(signer::address_of(&player)) == 0, 0);
    }

    #[test]
    fun test_shoot_1_apt_twice_and_goal_shot_success() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        coin::register<AptosCoin>(&admin);
        init_module(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        
        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 0, 0);

        set_ticket_price(&admin, 100000000);
        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 100000000, 0);

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework_account);
        aptos_coin::mint(&aptos_framework_account, @0xCAFE, 100000000 * 2);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        assert!(coin::balance<AptosCoin>(signer::address_of(&player)) == 100000000 * 2, 0);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        timestamp::fast_forward_seconds(SHOOT_DURATION + 1);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter(&state.event_handlers.shoot_events) == 2, 0);

        let state = borrow_global<State>(resource_account_address);
        let all_balance = coin::balance<AptosCoin>(resource_account_address);
        let reward = coin::balance<AptosCoin>(resource_account_address) * state.reward_percentage / 100;
        let admin_reward = coin::balance<AptosCoin>(resource_account_address) * state.admin_percentage / 100;
        let player_balance_before = coin::balance<AptosCoin>(signer::address_of(&player));

        timestamp::fast_forward_seconds(SHOOT_DURATION - 1);
        goal_shot(&admin, signer::address_of(&player));

        let player_balance_after = coin::balance<AptosCoin>(signer::address_of(&player));

        assert!(player_balance_after - player_balance_before == reward, 0);
        assert!(coin::balance<AptosCoin>(signer::address_of(&admin)) == admin_reward, 0);
        assert!(coin::balance<AptosCoin>(resource_account_address) == all_balance - (reward + admin_reward), 0);
    }

    #[test]
    #[expected_failure(abort_code = EDEADLINE_HAS_PASSED)]
    fun test_shoot_1_apt_twice_and_goal_shot_failure_deadline_has_passed() acquires State {
        let aptos_framework_account = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework_account);

        let admin = account::create_account_for_test(@admin);
        coin::register<AptosCoin>(&admin);
        init_module(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        
        let resource_account_address = get_resource_account_address();

        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 0, 0);

        set_ticket_price(&admin, 100000000);
        let state = borrow_global<State>(resource_account_address);
        assert!(state.ticket_price == 100000000, 0);

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework_account);
        aptos_coin::mint(&aptos_framework_account, @0xCAFE, 100000000 * 2);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        assert!(coin::balance<AptosCoin>(signer::address_of(&player)) == 100000000 * 2, 0);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        timestamp::fast_forward_seconds(SHOOT_DURATION + 1);

        shoot(&player);

        let state = borrow_global<State>(resource_account_address);
        let shoot_deadline = *simple_map::borrow(&state.shoot_deadline_mapper, &signer::address_of(&player));
        assert!(shoot_deadline == timestamp::now_seconds() + SHOOT_DURATION, 0);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter(&state.event_handlers.shoot_events) == 2, 0);

        let state = borrow_global<State>(resource_account_address);
        let all_balance = coin::balance<AptosCoin>(resource_account_address);
        let reward = coin::balance<AptosCoin>(resource_account_address) * state.reward_percentage / 100;
        let admin_reward = coin::balance<AptosCoin>(resource_account_address) * state.admin_percentage / 100;
        let player_balance_before = coin::balance<AptosCoin>(signer::address_of(&player));

        timestamp::fast_forward_seconds(SHOOT_DURATION + 1);
        goal_shot(&admin, signer::address_of(&player));

        let player_balance_after = coin::balance<AptosCoin>(signer::address_of(&player));

        assert!(player_balance_after - player_balance_before == reward, 0);
        assert!(coin::balance<AptosCoin>(signer::address_of(&admin)) == admin_reward, 0);
        assert!(coin::balance<AptosCoin>(resource_account_address) == all_balance - (reward + admin_reward), 0);
    }

}