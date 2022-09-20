import Error "mo:base/Error";
import Types "Types";
import Prim "mo:⛔";
import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Cycles "mo:base/ExperimentalCycles";
import Debug "mo:base/Debug";


actor class ExchangeRate() = this {

    // How many data point can be returned as maximum.
    // Given that 2MB is max-allow canister response size, and each <Timestamp, Rate> pair
    // should be less that 20 bytes. Maximum data points could be returned for each
    // call can be as many as 2MB / 20B = 100000.
    let MAX_DATA_PONTS_CANISTER_RESPONSE: Nat = 100000;

    // Remote fetch interval in secs. It is only the canister returned interval
    // that is dynamic according to the data size needs to be returned.
    let REMOTE_FETCH_GRANULARITY: Nat64 = 60;

    // For how many rounds of heartbeat, make a http_request call.
    let RATE_LIMIT_FACTOR: Nat = 5;

    // How many data points in each Coinbase API call. Maximum allowed is 300
    let DATA_POINTS_PER_API: Nat64 = 200;

    // Maximum raw Coinbase API response size. This field is used by IC to calculate circles cost per HTTP call.
    // Here is how this number is derived:
    // Each Coinbase API call return an array of array, and each sub-array look like below:
    // [
    //     1652454000,
    //     9.51,
    //     9.6,
    //     9.55,
    //     9.54,
    //     4857.1892
    // ],
    // Each field of this sub-arry takes less than 10 bytes. Then,
    // 10 (bytes per field) * 6 (fields per timestamp) * 200 (timestamps)
    let MAX_RESPONSE_BYTES: Nat64 = 10 * 6 * DATA_POINTS_PER_API;

    var FETCHED = HashMap.HashMap<Types.Timestamp, Types.Rate>(Nat.Maximum, Nat.equal, Nat.hash);
    var REQUESTED = HashMap.HashMap<Types.Timestamp, Nat>(Nat.Maximum, Nat.equal, Nat.hash);
    var RATE_COUNTER: Nat = 0;

    type IC = actor {
        http_request : Types.CanisterHttpRequestArgs -> async Types.CanisterHttpResponsePayload;
    };

    let ic : IC = actor("aaaaa-aa");

    public query func transform(raw: Types.CanisterHttpResponsePayload) : async Types.CanisterHttpResponsePayload {
        let transformed: Types.CanisterHttpResponsePayload = {
            status = raw.status;
            body = raw.body;
            headers = [
                { name = "Content-Security-Policy"; value = "default-src 'self'"; },
                { name = "Referrer-Policy"; value = "strict-origin"; },
                { name = "Permissions-Policy"; value = "geolocation=(self)"; },
                { name = "Strict-Transport-Security"; value = "max-age=63072000"; },
                { name = "X-Frame-Options"; value = "DENY"; },
                { name = "X-Content-Type-Options"; value = "nosniff"; },
            ];
        };
        transformed
    };


    // Canister heartbeat. Process one item in queue
    system func heartbeat(): async () {
        var should_fetch: Bool = false;
        if (RATE_COUNTER == 0) {
            should_fetch := true;
        };
        RATE_COUNTER := (RATE_COUNTER + 1) % RATE_LIMIT_FACTOR;
        if should_fetch {
            await get_next_rate();
        };
    };

    /*
    Get rates for a time range defined by start time and end time. This function can be invoked
    as HTTP update call.
    */
    public shared(msg) func get_rates(range: Types.TimeRange) : async (Types.RatesWithInterval) {
        // round down start time and end time to the minute (chop off seconds), to be checked in the hashmap
        let start_min: Nat64 = range.start / REMOTE_FETCH_GRANULARITY;
        let end_min: Nat64 = range.end / REMOTE_FETCH_GRANULARITY;

        // compose a return structure
        var fetched = HashMap.HashMap<Types.Timestamp, Types.Rate>(Nat.Maximum, Nat.equal, Nat.hash);
        // pull available ranges from hashmap
        let requested_min = start_min;
        while (requested_min <= end_min) {
            let requested = requested_min * REMOTE_FETCH_GRANULARITY;
            switch (FETCHED.get(requested)) {
                case null {
                    // The fetched slot is within user requested range. Add to result for later returning.
                    Debug.print("Found " # requested # " in map!");
                    fetched.put(requested, FETCHED.get(requested));
                };
                case (?_) {
                    Debug.print("Did not find " # requested # " in map!");
                    // asynchoronously request downloads for unavailable ranges
                    add_job_to_job_set(requested);
                };
            };
        };

        // return sampled rates for available ranges
        await sample_with_interval(fetched)
    };

    public func sample_with_interval(fetched: HashMap.HashMap<Types.Timestamp, Types.Rate>) : async (Types.RatesWithInterval) {
        // in order to make sure that returned data do not exceed 2MB, which is about
        // ~1M data points, calculate interval when data points count is beyond 900K.
        let interval_options: [Nat] = [
            1,       // 1 data point every minute
            5,       // 1 data point every 5 minutes
            15,      // 1 data point every 15 minutes
            60,      // 1 data point every hour
            60 * 12, // 1 data point every 12 hours
            60 * 24, // 1 data point every day
        ];
        for (i in interval_options.vals()) {
            if (fetched.len() / i < MAX_DATA_PONTS_CANISTER_RESPONSE) {
                return Types.RatesWithInterval {
                    interval = i * REMOTE_FETCH_GRANULARITY as Nat;
                    rates = HashMap.mapFilter(fetched, func (x : Nat) : Bool { x % (x as Nat64) == 0 });
                };
            };
        };
        Debug.trap("This shouldn't be happening! Couldn't find an inteval that can keep total data points count in " # MAX_DATA_PONTS_CANISTER_RESPONSE);
    };

    public func add_job_to_job_set(job: Types.Timestamp) : () {
        // Since Coinbase API allows DATA_POINTS_PER_API data points (5 hours of data) per API call,
        // and the response size is roughly 14KB, which is way below max_response_size,
        // we normalize the job to the beginning of 5 hours.
        let normalized_job = job / (REMOTE_FETCH_GRANULARITY * DATA_POINTS_PER_API)
            * (REMOTE_FETCH_GRANULARITY * DATA_POINTS_PER_API);
        REQUESTED.put(normalized_job, 0);
    };

    /*
    Triggered by heartbeat() function to pick up the next job in the pipe for remote service call.
    */
    public func get_next_rate(): async() {

        // Get the next downloading job
        if (REQUESTED.len() == 0) {
            Debug.print("Request set is empty, no more jobs to fetch.");
            return;
        };

        let job_id: Nat64 = REQUESTED.keys()[0];
        if (not REQUESTED.remove(job_id)) {
            Debug.print("Item not found in job set.");
            return;
        };

        switch (FETCHED.get(job_id)) {
            case null {
                // The requested time rate isn't found in map. Send a canister get_rate call to self
                Debug.print("Fetching job " # job_id # " now.");
            };
            case (?_) {
                // If this job has already been downloaded. Only downloading it if doesn't already exist.
                Debug.print(
                    "Rate for " # job_id # " is already downloaded. Skipping downloading again.",
                );
                return;
            };
        };

        if (job_id != 0) {
            await get_rate(job_id);
        };
    };

    /*
    A function to call IC http_request function with sample interval of REMOTE_FETCH_GRANULARITY seconds. Each API
    call fetches DATA_POINTS_PER_API data points, which is equivalent of DATA_POINTS_PER_API minutes of data.
    */
    public shared (msg) func get_rate(job: Types.Timestamp): async() {
        let start_timestamp: Types.Timestamp = job;
        let end_timestamp: Types.Timestamp = job + REMOTE_FETCH_GRANULARITY * DATA_POINTS_PER_API;

        let host: Text = "api.pro.coinbase.com";
        // prepare system http_request call
        let request_headers = [
            { name = "Host"; value = host # ":443"; },
            { name = "User-Agent"; value = "exchange_rate_canister"; },
        ];
        let url = "https://" # host # "/products/ICP-USD/candles?granularity=" # REMOTE_FETCH_GRANULARITY # "&start=" # start_timestamp # "&end=" # end_timestamp;
        Debug.print(url)
    };

    public shared (msg) func call_http(url: Text) : async { #Ok : { response: Types.CanisterHttpResponsePayload }; #Err : Text } {
        let request: Types.CanisterHttpRequestArgs = {
            url = url;
            max_response_bytes = null;
            headers = [];
            body = null;
            method = #get;
            transform = ?(#function(transform));
        };
        try {
            Cycles.add(300_000_000_000);
            let response = await ic.http_request(request);
            #Ok({response})
        } catch (err) {
            #Err(Error.message(err))
        }
    };
}
