module overmind::bingo_core {
    use std::signer;
    use aptos_framework::account;
    use std::string::String;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use std::vector;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::timestamp;
    use std::option::Option;
    use std::option;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::event::EventHandle;
    use overmind::bingo_events::{CreateGameEvent, InsertNumberEvent, JoinGameEvent, BingoEvent, CancelGameEvent};
    use aptos_framework::event;
    use overmind::bingo_events;
    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::aptos_coin;

    ////////////
    // ERRORS //
    ////////////

    const ERROR_SIGNER_NOT_ADMIN: u64 = 0;
    const ERROR_INVALID_START_TIMESTAMP: u64 = 1;
    const ERROR_BINGO_NOT_INITIALIZED: u64 = 2;
    const ERROR_GAME_NAME_TAKEN: u64 = 3;
    const ERROR_INVALID_NUMBER: u64 = 4;
    const ERROR_GAME_DOES_NOT_EXIST: u64 = 5;
    const ERROR_GAME_NOT_STARTED_YET: u64 = 6;
    const ERROR_NUMBER_DUPLICATED: u64 = 7;
    const ERROR_INVALID_AMOUNT_OF_COLUMNS_IN_PICKED_NUMBERS: u64 = 8;
    const ERROR_INVALID_AMOUNT_OF_NUMBERS_IN_COLUMN: u64 = 9;
    const ERROR_COLUMN_HAS_INVALID_NUMBER: u64 = 10;
    const ERROR_GAME_ALREADY_STARTED: u64 = 11;
    const ERROR_INSUFFICIENT_FUNDS: u64 = 12;
    const ERROR_PLAYER_ALREADY_JOINED: u64 = 13;
    const ERROR_GAME_HAS_ENDED: u64 = 14;
    const ERROR_PLAYER_NOT_JOINED: u64 = 15;
    const ERROR_PLAYER_HAVE_NOT_WON: u64 = 16;

    // Static seed
    const BINGO_SEED: vector<u8> = b"BINGO";

    /*
        Resource being stored in admin account. Holds address of bingo game's PDA account
    */
    struct State has key {
        // PDA address
        bingo: address
    }

    /*
        Resource holding data about on current and past games
    */
    struct Bingo has key {
        // List of games
        games: SimpleMap<String, Game>,
        // SignerCapability instance to recreate PDA's signer
        cap: SignerCapability,
        // Events
        create_game_events: EventHandle<CreateGameEvent>,
        cancel_game_events: EventHandle<CancelGameEvent>
    }

    /*
        Struct holding data about a single game
    */
    struct Game has store {
        // List of players participating in a game
        players: SimpleMap<address, vector<vector<u8>>>,
        // Number of APT needed to participate in a game
        entry_fee: u64,
        // Timestamp of game's start
        start_timestamp: u64,
        // Numbers drawn by the admin for a game
        drawn_numbers: vector<u8>,
        // Boolean flag indicating if a game is ongoing or has finished
        is_finished: bool,
        // Events
        insert_number_events: EventHandle<InsertNumberEvent>,
        join_game_events: EventHandle<JoinGameEvent>,
        bingo_events: EventHandle<BingoEvent>
    }

    /*
        Initializes bingo
        @param admin - signer of the admin
    */
    public entry fun init(admin: &signer) {
        assert_admin(signer::address_of(admin));

        let (resource_account_signer, cap) = account::create_resource_account(admin, BINGO_SEED);
        coin::register<AptosCoin>(&resource_account_signer);
        move_to(admin, State { bingo: signer::address_of(&resource_account_signer) });
        move_to(&resource_account_signer, Bingo {
            games: simple_map::create(),
            cap,
            create_game_events: account::new_event_handle(&resource_account_signer),
            cancel_game_events: account::new_event_handle(&resource_account_signer)
        });
    }

    /*
        Creates a new game of bingo
        @param admin - signer of the admin
        @param game_name - name of the game
        @param entry_fee - entry fee of the game
        @param start_timestamp - start timestamp of the game
    */
    public entry fun create_game(
        admin: &signer,
        game_name: String,
        entry_fee: u64,
        start_timestamp: u64
    ) acquires State, Bingo {
        assert_start_timestamp_is_valid(start_timestamp);

        let admin_address = signer::address_of(admin);
        assert_bingo_initialized(admin_address);

        let state = borrow_global<State>(admin_address);
        let bingo = borrow_global_mut<Bingo>(state.bingo);
        assert_game_name_not_taken(&bingo.games, &game_name);

        let resource_account_signer = account::create_signer_with_capability(&bingo.cap);
        let game = Game {
            players: simple_map::create(),
            entry_fee,
            start_timestamp,
            drawn_numbers: vector::empty(),
            is_finished: false,
            insert_number_events: account::new_event_handle(&resource_account_signer),
            join_game_events: account::new_event_handle(&resource_account_signer),
            bingo_events: account::new_event_handle(&resource_account_signer)
        };
        simple_map::add(&mut bingo.games, game_name, game);

        event::emit_event(
            &mut bingo.create_game_events,
            bingo_events::new_create_game_event(game_name, entry_fee, start_timestamp, timestamp::now_seconds())
        );
    }

    /*
        Adds a number drawn by the admin to the vector of drawn numbers for a provided game
        @param admin - signer of the admin
        @param game_name - name of the game
        @param number - number drawn by the admin
    */
    public entry fun insert_number(admin: &signer, game_name: String, number: u8) acquires State, Bingo {
        assert_inserted_number_is_valid(number);

        let admin_address = signer::address_of(admin);
        assert_bingo_initialized(admin_address);

        let state = borrow_global<State>(admin_address);
        let bingo = borrow_global_mut<Bingo>(state.bingo);
        assert_game_exists(&bingo.games, &game_name);

        let game = simple_map::borrow_mut(&mut bingo.games, &game_name);
        assert_game_already_stared(game.start_timestamp);
        assert_number_not_duplicated(&game.drawn_numbers, &number);

        vector::push_back(&mut game.drawn_numbers, number);

        event::emit_event(
            &mut game.insert_number_events,
            bingo_events::new_inser_number_event(game_name, number, timestamp::now_seconds())
        );
    }

    /*
        Adds the signer to the list of participants of the provided game
        @param player - player wanting to join to the game
        @param game_name - name of the game
        @param numbers - vector of numbers picked by the player
            (should be 5x5 accordingly to https://pl.wikipedia.org/wiki/Bingo#Plansze_do_Bingo)
    */
    public entry fun join_game(player: &signer, game_name: String, numbers: vector<vector<u8>>) acquires State, Bingo {
        assert_bingo_initialized(@admin);
        assert_correct_amount_of_picked_numbers(&numbers);
        assert_numbers_are_picked_correctly(&numbers);

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global_mut<Bingo>(state.bingo);
        assert_game_exists(&bingo.games, &game_name);

        let player_address = signer::address_of(player);
        let game = simple_map::borrow_mut(&mut bingo.games, &game_name);
        assert_game_not_started(game.start_timestamp);
        assert_suffiecient_funds_to_join(player_address, game.entry_fee);
        assert_player_not_joined_yet(&game.players, &player_address);

        simple_map::add(&mut game.players, player_address, numbers);
        coin::transfer<AptosCoin>(player, state.bingo, game.entry_fee);

        event::emit_event(
            &mut game.join_game_events,
            bingo_events::new_join_game_event(game_name, player_address, numbers, timestamp::now_seconds())
        );
    }

    /*
        Allows a player to declare bingo for provided game
        @param player - player participating in the game
        @param game_name - name of the game
    */
    public entry fun bingo(player: &signer, game_name: String) acquires State, Bingo {
        assert_bingo_initialized(@admin);

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global_mut<Bingo>(state.bingo);
        assert_game_exists(&bingo.games, &game_name);

        let player_address = signer::address_of(player);
        let game = simple_map::borrow_mut(&mut bingo.games, &game_name);
        assert_game_not_finished(game.is_finished);
        assert_player_joined(&game.players, &player_address);

        let player_numbers = simple_map::borrow(&game.players, &player_address);
        assert_player_won(&game.drawn_numbers, *player_numbers);

        game.is_finished = true;

        let resource_account_signer = account::create_signer_with_capability(&bingo.cap);
        let amount = simple_map::length(&game.players) * game.entry_fee;
        coin::transfer<AptosCoin>(&resource_account_signer, player_address, amount);

        event::emit_event(
            &mut game.bingo_events,
            bingo_events::new_bingo_event(game_name, player_address, timestamp::now_seconds())
        );
    }

    /*
        Cancels an ongoing game
        @param admin - signer of the admin
        @param game_name - name of the game
    */
    public entry fun cancel_game(admin: &signer, game_name: String) acquires State, Bingo {
        assert_bingo_initialized(signer::address_of(admin));

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global_mut<Bingo>(state.bingo);
        assert_game_exists(&bingo.games, &game_name);

        let game = simple_map::borrow_mut(&mut bingo.games, &game_name);
        assert_game_not_finished(game.is_finished);

        game.is_finished = true;

        let resource_account_signer = account::create_signer_with_capability(&bingo.cap);
        let (players, _) = simple_map::to_vec_pair(game.players);
        vector::for_each(players, |player| {
           coin::transfer<AptosCoin>(&resource_account_signer, player, game.entry_fee);
        });

        event::emit_event(
            &mut bingo.cancel_game_events,
            bingo_events::new_cance_game_event(game_name, timestamp::now_seconds())
        );
    }

    /*
        Checks if a player has bingo in either column, row or diagonal
        @param drawn_numbers - numbers drawn by the admin
        @param player_numbers - numbers picked by the player
        @returns - true if the player has bingo, otherwise false
    */
    fun check_player_numbers(drawn_numbers: &vector<u8>, player_numbers: vector<vector<u8>>): bool {
        let temp = vector::map(player_numbers, |column| {
            let new_column = vector::empty();
            let counter = 0;
            while (counter < vector::length(&column)) {
                let number = *vector::borrow(&column, counter);
                if (vector::contains(drawn_numbers, &number) || number == 0) {
                    vector::push_back(&mut new_column, option::none());
                } else {
                    vector::push_back(&mut new_column, option::some(number));
                };

                counter = counter + 1;
            };
            new_column
        });

        check_columns(&temp) || check_diagonals(&temp) || check_rows(&temp)
    }

    /*
        Checks if a player has bingo in any column
        @param player_numbers - numbers picked by the player
        @returns - true if player has bingo in any column, otherwise false
    */
    inline fun check_columns(player_numbers: &vector<vector<Option<u8>>>): bool {
        let counter = 0;
        let final_result = false;
        while (counter < vector::length(player_numbers)) {
            let result = vector::all(vector::borrow(player_numbers, counter), |number| {
                option::is_none(number)
            });

            if (result) {
                final_result = result;
                break
            };

            counter = counter + 1;
        };

        final_result
    }

    /*
        Checks if a player has bingo in any row
        @param player_numbers - numbers picked by the player
        @returns - true if player has bingo in any row, otherwise false
    */
    inline fun check_rows(player_numbers: &vector<vector<Option<u8>>>): bool {
        let row_number = 0;
        let final_result = false;
        while (row_number < 5) {
            let result = vector::all(player_numbers, |column| {
                option::is_none(vector::borrow(column, row_number))
            });

            if (result) {
                final_result = result;
                break
            };

            row_number = row_number + 1;
        };

        final_result
    }

    /*
        Checks if a player has bingo in any diagonal
        @param player_numbers - numbers picked by the player
        @returns - true if player has bingo in any diagonal, otherwise false
    */
    inline fun check_diagonals(player_numbers: &vector<vector<Option<u8>>>): bool {
        let first_diagonal = true;
        let second_diagonal = true;
        let final_result = true;
        let counter = 0;
        while (counter < vector::length(player_numbers)) {
            let column = vector::borrow(player_numbers, counter);
            first_diagonal = first_diagonal && option::is_none(vector::borrow(column, counter));
            second_diagonal = second_diagonal &&
                option::is_none(vector::borrow(column, vector::length(column) - 1 - counter));

            if (!(first_diagonal || second_diagonal)) {
                final_result = false;
                break
            };

            counter = counter + 1;
        };

        final_result
    }

    /////////////
    // ASSERTS //
    /////////////

    inline fun assert_admin(admin: address) {
        assert!(admin == @admin, ERROR_SIGNER_NOT_ADMIN);
    }

    inline fun assert_start_timestamp_is_valid(start_timestamp: u64) {
        assert!(start_timestamp > timestamp::now_seconds(), ERROR_INVALID_START_TIMESTAMP);
    }

    inline fun assert_bingo_initialized(admin: address) acquires State {
        assert!(exists<State>(admin) && exists<Bingo>(borrow_global<State>(admin).bingo), ERROR_BINGO_NOT_INITIALIZED);
    }

    inline fun assert_game_name_not_taken(games: &SimpleMap<String, Game>, game_name: &String) {
        assert!(!simple_map::contains_key(games, game_name), ERROR_GAME_NAME_TAKEN);
    }

    inline fun assert_inserted_number_is_valid(number: u8) {
        assert!(0 < number && number < 76, ERROR_INVALID_NUMBER);
    }

    inline fun assert_game_exists(games: &SimpleMap<String, Game>, game_name: &String) {
        assert!(simple_map::contains_key(games, game_name), ERROR_GAME_DOES_NOT_EXIST);
    }

    inline fun assert_game_already_stared(start_timestamp: u64) {
        assert!(start_timestamp <= timestamp::now_seconds(), ERROR_GAME_NOT_STARTED_YET);
    }

    inline fun assert_number_not_duplicated(numbers: &vector<u8>, number: &u8) {
        assert!(!vector::contains(numbers, number), ERROR_NUMBER_DUPLICATED);
    }

    inline fun assert_correct_amount_of_picked_numbers(picked_numebrs: &vector<vector<u8>>) {
        assert!(vector::length(picked_numebrs) == 5, ERROR_INVALID_AMOUNT_OF_COLUMNS_IN_PICKED_NUMBERS);
        vector::for_each_ref(picked_numebrs, |column| {
           assert!(vector::length(column) == 5, ERROR_INVALID_AMOUNT_OF_NUMBERS_IN_COLUMN);
        });
    }

    inline fun assert_numbers_are_picked_correctly(picked_numbers: &vector<vector<u8>>) {
        let counter = 0;
        while (counter < vector::length(picked_numbers)) {
            let column = vector::borrow(picked_numbers, counter);
            let offset = (counter as u8) * 15;
            let number_counter = 0;
            while (number_counter < vector::length(column)) {
                let number = vector::borrow(column, number_counter);
                if (counter == 2 && number_counter == 2) {
                    assert!(*number == 0, ERROR_COLUMN_HAS_INVALID_NUMBER);
                } else {
                    assert!(*number >= 1 + offset && *number <= 15 + offset, ERROR_COLUMN_HAS_INVALID_NUMBER);
                };

                number_counter = number_counter + 1;
            };

            counter = counter + 1;
        }
    }

    inline fun assert_game_not_started(start_timestamp: u64) {
        assert!(start_timestamp > timestamp::now_seconds(), ERROR_GAME_ALREADY_STARTED);
    }

    inline fun assert_suffiecient_funds_to_join(player: address, entry_fee: u64) {
        assert!(coin::balance<AptosCoin>(player) >= entry_fee, ERROR_INSUFFICIENT_FUNDS);
    }

    inline fun assert_player_not_joined_yet(players: &SimpleMap<address, vector<vector<u8>>>, player: &address) {
        assert!(!simple_map::contains_key(players, player), ERROR_PLAYER_ALREADY_JOINED);
    }

    inline fun assert_game_not_finished(is_finished: bool) {
        assert!(!is_finished, ERROR_GAME_HAS_ENDED);
    }

    inline fun assert_player_joined(players: &SimpleMap<address, vector<vector<u8>>>, player: &address) {
        assert!(simple_map::contains_key(players, player), ERROR_PLAYER_NOT_JOINED);
    }

    inline fun assert_player_won(drawn_numbers: &vector<u8>, player_numbers: vector<vector<u8>>) {
        assert!(check_player_numbers(drawn_numbers, player_numbers), ERROR_PLAYER_HAVE_NOT_WON);
    }

    ///////////
    // TESTS //
    ///////////

    #[test]
    fun test_init() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        assert!(exists<State>(@admin), 0);

        let state = borrow_global<State>(@admin);
        assert!(state.bingo == account::create_resource_address(&@admin, b"BINGO"), 1);
        assert!(coin::is_account_registered<AptosCoin>(state.bingo), 2);
        assert!(exists<Bingo>(state.bingo), 3);

        let bingo = borrow_global<Bingo>(state.bingo);
        assert!(simple_map::length(&bingo.games) == 0, 4);
        assert!(&bingo.cap == &account::create_test_signer_cap(state.bingo), 5);
        assert!(event::counter(&bingo.create_game_events) == 0, 6);
        assert!(event::counter(&bingo.cancel_game_events) == 0, 7);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_init_signer_not_admin() {
        let user = account::create_account_for_test(@0xCAFE);
        init(&user);
    }

    #[test]
    fun test_create_game() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 555;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global<Bingo>(state.bingo);
        assert!(simple_map::length(&bingo.games) == 1, 0);
        assert!(simple_map::contains_key(&bingo.games, &game_name), 1);
        assert!(&bingo.cap == &account::create_test_signer_cap(state.bingo), 2);
        assert!(event::counter(&bingo.create_game_events) == 1, 3);
        assert!(event::counter(&bingo.cancel_game_events) == 0, 4);

        let game = simple_map::borrow(&bingo.games, &game_name);
        assert!(simple_map::length(&game.players) == 0, 5);
        assert!(game.entry_fee == entry_fee, 6);
        assert!(game.start_timestamp == start_timestamp, 7);
        assert!(vector::length(&game.drawn_numbers) == 0, 8);
        assert!(!game.is_finished, 9);
        assert!(event::counter(&game.insert_number_events) == 0, 10);
        assert!(event::counter(&game.join_game_events) == 0, 11);
        assert!(event::counter(&game.bingo_events) == 0, 12);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_game_invalid_timestamp() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        timestamp::fast_forward_seconds(100);

        let admin = account::create_account_for_test(@admin);
        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 99;
        create_game(&admin, game_name, entry_fee, start_timestamp);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_game_bingo_not_initialized() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 555;
        create_game(&admin, game_name, entry_fee, start_timestamp);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_create_game_name_taken() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 555;
        create_game(&admin, game_name, entry_fee, start_timestamp);
        create_game(&admin, game_name, entry_fee, start_timestamp);
    }

    #[test]
    fun test_insert_number() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 555;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        timestamp::fast_forward_seconds(555);

        let number_drawn = 55;
        insert_number(&admin, game_name, number_drawn);

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global<Bingo>(state.bingo);
        assert!(simple_map::length(&bingo.games) == 1, 0);
        assert!(simple_map::contains_key(&bingo.games, &game_name), 1);
        assert!(&bingo.cap == &account::create_test_signer_cap(state.bingo), 2);
        assert!(event::counter(&bingo.create_game_events) == 1, 3);
        assert!(event::counter(&bingo.cancel_game_events) == 0, 4);

        let game = simple_map::borrow(&bingo.games, &game_name);
        assert!(simple_map::length(&game.players) == 0, 5);
        assert!(game.entry_fee == entry_fee, 6);
        assert!(game.start_timestamp == start_timestamp, 7);
        assert!(vector::length(&game.drawn_numbers) == 1, 8);
        assert!(vector::contains(&game.drawn_numbers, &number_drawn), 9);
        assert!(!game.is_finished, 10);
        assert!(event::counter(&game.insert_number_events) == 1, 11);
        assert!(event::counter(&game.join_game_events) == 0, 12);
        assert!(event::counter(&game.bingo_events) == 0, 13);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_insert_number_invalid() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        let game_name = string::utf8(b"The first game");
        let number_drawn = 99;
        insert_number(&admin, game_name, number_drawn);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_insert_number_bingo_not_initialized() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        let game_name = string::utf8(b"The first game");
        let number_drawn = 55;
        insert_number(&admin, game_name, number_drawn);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_insert_number_game_does_not_exist() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let number_drawn = 55;
        insert_number(&admin, game_name, number_drawn);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_inser_number_game_not_started_yet() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 555;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let game_name = string::utf8(b"The first game");
        let number_drawn = 55;
        insert_number(&admin, game_name, number_drawn);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_insert_number_duplicated() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 555;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        timestamp::fast_forward_seconds(555);

        let number_drawn = 55;
        insert_number(&admin, game_name, number_drawn);
        insert_number(&admin, game_name, number_drawn);
    }

    #[test]
    fun test_join_game() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5648964;
        let start_timestamp = 555;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let player = account::create_account_for_test(@0xCAFE);
        let numbers = vector[
            vector[1, 2, 5, 4, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        coin::register<AptosCoin>(&player);
        aptos_coin::mint(&aptos_framework, @0xCAFE, entry_fee + 1);
        join_game(&player, game_name, numbers);

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global<Bingo>(state.bingo);
        assert!(simple_map::length(&bingo.games) == 1, 0);
        assert!(simple_map::contains_key(&bingo.games, &game_name), 1);
        assert!(&bingo.cap == &account::create_test_signer_cap(state.bingo), 2);
        assert!(event::counter(&bingo.create_game_events) == 1, 3);
        assert!(event::counter(&bingo.cancel_game_events) == 0, 4);

        let game = simple_map::borrow(&bingo.games, &game_name);
        assert!(simple_map::length(&game.players) == 1, 5);
        assert!(simple_map::contains_key(&game.players, &@0xCAFE), 6);
        assert!(simple_map::borrow(&game.players, &@0xCAFE) == &numbers, 7);
        assert!(game.entry_fee == entry_fee, 8);
        assert!(game.start_timestamp == start_timestamp, 9);
        assert!(vector::length(&game.drawn_numbers) == 0, 10);
        assert!(!game.is_finished, 11);
        assert!(event::counter(&game.insert_number_events) == 0, 12);
        assert!(event::counter(&game.join_game_events) == 1, 13);
        assert!(event::counter(&game.bingo_events) == 0, 14);
        assert!(coin::balance<AptosCoin>(@0xCAFE) == 1, 15);
        assert!(coin::balance<AptosCoin>(state.bingo) == entry_fee, 16);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_join_game_bingo_not_initialized() acquires State, Bingo {
        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 4, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 41, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_join_game_invalid_number_of_columns() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 4, 8],
            vector[16, 17, 20, 19, 30],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 9, location = Self)]
    fun test_join_game_invalid_amount_of_numbers_in_column() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 4, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_join_game_invalid_numbers_first_column() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 16, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_join_game_invalid_numbers_second_column() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 11, 8],
            vector[16, 17, 44, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_join_game_invalid_numbers_third_column() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 11, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_join_game_invalid_numbers_fourth_column() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[5, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_join_game_invalid_numbers_fifth_column() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 18]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_join_game_does_not_exist() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 11, location = Self)]
    fun test_join_game_already_started() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        timestamp::fast_forward_seconds(45462);

        let player = account::create_account_for_test(@0xCAFE);
        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
    }

    #[test]
    #[expected_failure(abort_code = 12, location = Self)]
    fun test_join_game_insufficient_funds() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        aptos_coin::mint(&aptos_framework, @0xCAFE, 44564);

        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);

        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_join_game_player_already_joined() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        aptos_coin::mint(&aptos_framework, @0xCAFE, 2 * entry_fee);

        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
        join_game(&player, game_name, numbers);

        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_bingo() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        aptos_coin::mint(&aptos_framework, @0xCAFE, entry_fee);

        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);

        let another_player = account::create_account_for_test(@0xACE);
        coin::register<AptosCoin>(&another_player);
        aptos_coin::mint(&aptos_framework, @0xACE, entry_fee);

        let another_numbers = vector[
            vector[3, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[33, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&another_player, game_name, another_numbers);

        timestamp::fast_forward_seconds(45462);

        let drawn_numbers = vector[1, 16, 31, 46, 66];
        vector::for_each_ref(&drawn_numbers, |number| {
            insert_number(&admin, game_name, *number);
        });

        bingo(&player, game_name);

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global<Bingo>(state.bingo);
        assert!(simple_map::length(&bingo.games) == 1, 0);
        assert!(simple_map::contains_key(&bingo.games, &game_name), 1);
        assert!(&bingo.cap == &account::create_test_signer_cap(state.bingo), 2);
        assert!(event::counter(&bingo.create_game_events) == 1, 3);
        assert!(event::counter(&bingo.cancel_game_events) == 0, 4);

        let game = simple_map::borrow(&bingo.games, &game_name);
        assert!(simple_map::length(&game.players) == 2, 5);
        assert!(simple_map::contains_key(&game.players, &@0xCAFE), 6);
        assert!(simple_map::contains_key(&game.players, &@0xACE), 7);
        assert!(simple_map::borrow(&game.players, &@0xCAFE) == &numbers, 8);
        assert!(simple_map::borrow(&game.players, &@0xACE) == &another_numbers, 9);
        assert!(game.entry_fee == entry_fee, 10);
        assert!(game.start_timestamp == start_timestamp, 11);
        assert!(game.drawn_numbers == drawn_numbers, 12);
        assert!(game.is_finished, 13);
        assert!(event::counter(&game.insert_number_events) == 5, 14);
        assert!(event::counter(&game.join_game_events) == 2, 15);
        assert!(event::counter(&game.bingo_events) == 1, 16);
        assert!(coin::balance<AptosCoin>(state.bingo) == 0, 17);
        assert!(coin::balance<AptosCoin>(@0xACE) == 0, 18);
        assert!(coin::balance<AptosCoin>(@0xCAFE) == 2 * entry_fee, 19);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_bingo_not_initialized() acquires State, Bingo {
        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        bingo(&player, game_name);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_bingo_game_does_not_exist() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let player = account::create_account_for_test(@0xCAFE);
        let game_name = string::utf8(b"The first game");
        bingo(&player, game_name);
    }

    #[test]
    #[expected_failure(abort_code = 14, location = Self)]
    fun test_bingo_game_has_ended() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        {
            let state = borrow_global<State>(@admin);
            let bingo = borrow_global_mut<Bingo>(state.bingo);
            let game = simple_map::borrow_mut(&mut bingo.games, &game_name);
            game.is_finished = true;
        };

        let player = account::create_account_for_test(@0xCAFE);
        bingo(&player, game_name);
    }

    #[test]
    #[expected_failure(abort_code = 15, location = Self)]
    fun test_bingo_player_not_joined() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let player = account::create_account_for_test(@0xCAFE);
        bingo(&player, game_name);
    }

    #[test]
    #[expected_failure(abort_code = 16, location = Self)]
    fun test_bingo_player_not_won() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        aptos_coin::mint(&aptos_framework, @0xCAFE, entry_fee);

        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);
        bingo(&player, game_name);

        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_cancel_game() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let player = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player);
        aptos_coin::mint(&aptos_framework, @0xCAFE, entry_fee);

        let numbers = vector[
            vector[1, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[31, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&player, game_name, numbers);

        let another_player = account::create_account_for_test(@0xACE);
        coin::register<AptosCoin>(&another_player);
        aptos_coin::mint(&aptos_framework, @0xACE, entry_fee);

        let another_numbers = vector[
            vector[3, 2, 5, 10, 8],
            vector[16, 17, 20, 19, 30],
            vector[33, 45, 0, 42, 43],
            vector[46, 50, 54, 49, 55],
            vector[66, 61, 65, 70, 69]
        ];
        join_game(&another_player, game_name, another_numbers);

        cancel_game(&admin, game_name);

        let state = borrow_global<State>(@admin);
        let bingo = borrow_global<Bingo>(state.bingo);
        assert!(simple_map::length(&bingo.games) == 1, 0);
        assert!(simple_map::contains_key(&bingo.games, &game_name), 1);
        assert!(&bingo.cap == &account::create_test_signer_cap(state.bingo), 2);
        assert!(event::counter(&bingo.create_game_events) == 1, 3);
        assert!(event::counter(&bingo.cancel_game_events) == 1, 4);

        let game = simple_map::borrow(&bingo.games, &game_name);
        assert!(simple_map::length(&game.players) == 2, 5);
        assert!(simple_map::contains_key(&game.players, &@0xCAFE), 6);
        assert!(simple_map::contains_key(&game.players, &@0xACE), 7);
        assert!(simple_map::borrow(&game.players, &@0xCAFE) == &numbers, 8);
        assert!(simple_map::borrow(&game.players, &@0xACE) == &another_numbers, 9);
        assert!(game.entry_fee == entry_fee, 10);
        assert!(game.start_timestamp == start_timestamp, 11);
        assert!(vector::length(&game.drawn_numbers) == 0, 12);
        assert!(game.is_finished, 13);
        assert!(event::counter(&game.insert_number_events) == 0, 14);
        assert!(event::counter(&game.join_game_events) == 2, 15);
        assert!(event::counter(&game.bingo_events) == 0, 16);
        assert!(coin::balance<AptosCoin>(state.bingo) == 0, 17);
        assert!(coin::balance<AptosCoin>(@0xACE) == entry_fee, 18);
        assert!(coin::balance<AptosCoin>(@0xCAFE) == entry_fee, 19);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_cancel_game_bingo_not_initialized() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        let game_name = string::utf8(b"The first game");
        cancel_game(&admin, game_name);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_cancel_game_does_not_exist() acquires State, Bingo {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        cancel_game(&admin, game_name);
    }

    #[test]
    #[expected_failure(abort_code = 14, location = Self)]
    fun test_cancel_game_has_ended() acquires State, Bingo {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let game_name = string::utf8(b"The first game");
        let entry_fee = 5984255;
        let start_timestamp = 45462;
        create_game(&admin, game_name, entry_fee, start_timestamp);

        let game_name = string::utf8(b"The first game");
        cancel_game(&admin, game_name);
        cancel_game(&admin, game_name);
    }

    #[test]
    fun test_check_player_numbers() {
        let drawn_numbers = vector[1, 2, 4, 6, 11];
        let player_numbers = vector[
            vector[1, 2, 4, 6, 11],
            vector[16, 18, 17, 25, 24],
            vector[31, 40, 0, 39, 44],
            vector[46, 50, 55, 59, 51],
            vector[61, 62, 75, 74, 70]
        ];
        assert!(check_player_numbers(&drawn_numbers, player_numbers), 0);

        let drawn_numbers = vector[4, 17, 55, 75];
        let player_numbers = vector[
            vector[1, 2, 4, 6, 11],
            vector[16, 18, 17, 25, 24],
            vector[31, 40, 0, 39, 44],
            vector[46, 50, 55, 59, 51],
            vector[61, 62, 75, 74, 70]
        ];
        assert!(check_player_numbers(&drawn_numbers, player_numbers), 1);

        let drawn_numbers = vector[61, 50, 25, 11];
        let player_numbers = vector[
            vector[1, 2, 4, 6, 11],
            vector[16, 18, 17, 25, 24],
            vector[31, 40, 0, 39, 44],
            vector[46, 50, 55, 59, 51],
            vector[61, 62, 75, 74, 70]
        ];
        assert!(check_player_numbers(&drawn_numbers, player_numbers), 2);

        let drawn_numbers = vector[61, 50, 24, 11];
        let player_numbers = vector[
            vector[1, 2, 4, 6, 11],
            vector[16, 18, 17, 25, 24],
            vector[31, 40, 0, 39, 44],
            vector[46, 50, 55, 59, 51],
            vector[61, 62, 75, 74, 70]
        ];
        assert!(!check_player_numbers(&drawn_numbers, player_numbers), 3);
    }

    #[test]
    fun test_check_diagonals() {
        let numbers_fist_diagonal = vector[
            vector[option::none(), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::none(), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::none(), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::none()],
        ];
        assert!(check_diagonals(&numbers_fist_diagonal), 0);

        let numbers_second_diagonal = vector[
            vector[option::some(11), option::some(12), option::some(4), option::some(8), option::none()],
            vector[option::some(16), option::some(17), option::some(21), option::none(), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::none(), option::some(49), option::some(51), option::some(52)],
            vector[option::none(), option::some(61), option::some(70), option::some(74), option::some(63)],
        ];
        assert!(check_diagonals(&numbers_second_diagonal), 1);

        let numbers_both_diagonals = vector[
            vector[option::none(), option::some(12), option::some(4), option::some(8), option::none()],
            vector[option::some(16), option::none(), option::some(21), option::none(), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::none(), option::some(49), option::none(), option::some(52)],
            vector[option::none(), option::some(61), option::some(70), option::some(74), option::none()],
        ];
        assert!(check_diagonals(&numbers_both_diagonals), 2);

        let numbers_random_pattern = vector[
            vector[option::some(11), option::some(12), option::some(4), option::some(8), option::none()],
            vector[option::some(16), option::none(), option::some(21), option::none(), option::some(26)],
            vector[option::none(), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::none(), option::some(49), option::some(51), option::some(52)],
            vector[option::some(71), option::some(61), option::none(), option::some(74), option::some(63)],
        ];
        assert!(!check_diagonals(&numbers_random_pattern), 3);

        let all_numbers = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(!check_diagonals(&all_numbers), 4);
    }

    #[test]
    fun test_check_columns() {
        let first_column = vector[
            vector[option::none(), option::none(), option::none(), option::none(), option::none()],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(check_columns(&first_column), 0);

        let second_column = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::none(), option::none(), option::none(), option::none(), option::none()],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(check_columns(&second_column), 1);

        let third_column = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::none(), option::none(), option::none(), option::none(), option::none()],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(check_columns(&third_column), 2);

        let fourth_column = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::none(), option::none(), option::none(), option::none(), option::none()],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(check_columns(&fourth_column), 3);

        let fifth_column = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::none(), option::none(), option::none(), option::none(), option::none()],
        ];
        assert!(check_columns(&fifth_column), 4);

        let numbers_random_pattern = vector[
            vector[option::some(11), option::some(12), option::some(4), option::some(8), option::none()],
            vector[option::some(16), option::none(), option::some(21), option::none(), option::some(26)],
            vector[option::none(), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::none(), option::some(49), option::some(51), option::some(52)],
            vector[option::some(71), option::some(61), option::none(), option::some(74), option::some(63)],
        ];
        assert!(!check_columns(&numbers_random_pattern), 5);

        let all_numbers = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(!check_columns(&all_numbers), 6);
    }

    #[test]
    fun test_check_rows() {
        let first_row = vector[
            vector[option::none(), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::none(), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::none(), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::none(), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::none(), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(check_rows(&first_row), 0);

        let second_row = vector[
            vector[option::some(1), option::none(), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::none(), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::none(), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::none(), option::some(49), option::some(50), option::some(52)],
            vector[option::some(63), option::none(), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(check_rows(&second_row), 1);

        let third_row = vector[
            vector[option::some(1), option::some(12), option::none(), option::some(8), option::some(11)],
            vector[option::some(16), option::some(18), option::none(), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::none(), option::some(50), option::some(52)],
            vector[option::some(63), option::some(61), option::none(), option::some(74), option::some(75)],
        ];
        assert!(check_rows(&third_row), 2);

        let fourth_row = vector[
            vector[option::some(1), option::some(12), option::some(4), option::none(), option::some(11)],
            vector[option::some(16), option::some(18), option::some(21), option::none(), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::none(), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::none(), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::none(), option::some(75)],
        ];
        assert!(check_rows(&fourth_row), 3);

        let fifth_row = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::none()],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::none()],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::none()],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::none()],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::none()],
        ];
        assert!(check_rows(&fifth_row), 4);

        let numbers_random_pattern = vector[
            vector[option::some(11), option::some(12), option::some(4), option::some(8), option::none()],
            vector[option::some(16), option::none(), option::some(21), option::none(), option::some(26)],
            vector[option::none(), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::none(), option::some(49), option::some(51), option::some(52)],
            vector[option::some(71), option::some(61), option::none(), option::some(74), option::some(63)],
        ];
        assert!(!check_rows(&numbers_random_pattern), 5);

        let all_numbers = vector[
            vector[option::some(1), option::some(12), option::some(4), option::some(8), option::some(11)],
            vector[option::some(16), option::some(18), option::some(21), option::some(17), option::some(26)],
            vector[option::some(31), option::some(32), option::none(), option::some(44), option::some(41)],
            vector[option::some(46), option::some(51), option::some(49), option::some(50), option::some(52)],
            vector[option::some(63), option::some(61), option::some(70), option::some(74), option::some(75)],
        ];
        assert!(!check_rows(&all_numbers), 6);
    }
}