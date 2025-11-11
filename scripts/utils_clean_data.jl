function compute_illiq(trace_daily)
    trace_daily = copy(trace_daily)
    @subset!(trace_daily, :price.> 0., :price_lag.> 0.)
    transform!(trace_daily, :date=>(x->lastdayofmonth.(x))=>:eom)

    # Create col that checks number of days between daily rets - if above 7 the col should be false and otherwise true
    @transform!(groupby(trace_daily, [:cusip, :eom]), :date_diff = passmissing(Dates.value).(:date .- lag(:date, 1)))  # Get days between prices
    @rtransform!(trace_daily, :date_diff = :date_diff <= 7)  # Check days between prices is maximum 7
    trace_daily[ismissing.(trace_daily.date_diff), :date_diff] .= false

    # Create log price change col
    transform!(trace_daily, [:price, :price_lag]=>ByRow((p,p_lag)->log(p)-log(p_lag))=>:log_price)
    @rtransform!(trace_daily, :log_price = ifelse(:date_diff, :log_price, missing)) # Set log price changes with the check col false to missing

    # Compute Covariance - require at least 5 price pairs
    @transform!(groupby(trace_daily, [:cusip, :eom]), :log_price_lag = lag(:log_price, 1))  # NB! no requirement on day diff between log returns
    subset!(groupby(trace_daily, [:cusip, :eom]), [:log_price, :log_price_lag]=>ByRow((p, p_lag)->!ismissing(p)&&!ismissing(p_lag)))
    transform!(groupby(trace_daily, [:cusip, :eom]), :log_price=>(p->length(p) >= 5)=>:enough_price_pairs)
    @subset!(trace_daily, :enough_price_pairs.==true)


    return combine(groupby(trace_daily, [:cusip, :eom]), [:log_price, :log_price_lag]=>((p, p_lag)-> -1. * cov(p, p_lag))=>:illiq)
end

function get_dates(;trace=true)
    if trace==true
        dates = CSV.read("data/output/date_vectors_trace.csv", DataFrame) |>x->dropmissing(x,:RealDates) |>x->@transform(x, :cusip, :eom=lastdayofmonth.(:RealDates))
    else
        dates = CSV.read("data/output/date_vectors_warga_ice.csv", DataFrame) |>x->dropmissing(x,:RealDates) |>x->@transform(x, :cusip, :eom=lastdayofmonth.(:RealDates))
    end
    @transform!(groupby(dates, :cusip), :eom_lead=lead(:eom))
    datesv = @rsubset(dates, :eom==:eom_lead; view=true)
    datesv = @rsubset(datesv, :RD_indexes<2.0; view=true)
    @rtransform!(datesv, :eom=lastdayofmonth(:eom-Month(1)))
    select!(dates, :cusip, :eom, :CoupDates)
    return dates
end

function get_temporal_features(dates; n_expand=12)
    df = unique(dates, [:cusip, :eom])
    #df = @subset(df, :cusip.=="000336AE7")
    sort!(df, [:cusip, :eom])
    @transform!(groupby(df, :cusip), :remcoup=length(:cusip)-1:-1:0, :next_coup=lag(:CoupDates))

    df = calendar_fill(df, date_col=:eom, n_expand=n_expand)
    @transform!(groupby(df, :cusip), :remcoup=ffill(:remcoup), :next_coup=ffill(:CoupDates))#, :last_coup=ffill(:next_coup))
    @transform!(groupby(df, :cusip), :remcoup=bfill(:remcoup), :next_coup=bfill(:next_coup))#, :last_coup=ffill(:next_coup))
    @transform!(groupby(df, :cusip), :next_coup_lead=lead(:next_coup))#, :last_coup=ffill(:next_coup))
    dropmissing!(df, :next_coup)
    return df
end

function add_temporal_features(df; trace=true)
    dates = get_dates(trace=trace)
    dates1 = get_temporal_features(dates, n_expand=12)

    df = leftjoin(df, dates1, on=[:cusip, :date=>:eom]) |> x->sort(x, [:cusip, :date])
    @transform!(groupby(df, :cusip), :remcoup=bfill(:remcoup), :next_coup=bfill(:next_coup))

    # Handle cases where settlement date is after coupon payment
    # Match on year and month and if settlement date is then above coupon payment, lead remcoup and next_coup 1
    #dfv = @rsubset(df, !ismissing(:next_coup); view=true)
    
    dfv = @rsubset(df, (year(:settlement_date)==year(:next_coup)) && (month(:settlement_date)==month(:next_coup) && (day(:settlement_date)>day(:next_coup))); view=true)
    @rtransform!(dfv, :remcoup=:remcoup-1, :next_coup=:next_coup_lead)

    # Set next coup to missing in peiods where settlement_date > maturity
    #dfv = @rsubset(df, :settlement_date > :maturity; view=true)
    @rtransform!(df, :time_next_coup = Dates.value(:next_coup - :date)/360)#[!, [:cusip, :date, :next_coup, :tmt, :maturity, :time_next_coup]] |> x->sort(x, :time_next_coup)
    return df
end

function compute_reversal_flags!(df; price_col::Symbol=:price)
    n = nrow(df)
    
    if n <= 2
        return  # Always keep first and last (or all if ≤ 2 rows)
    end

    @inbounds for i in 2:(n - 1)
        p_prev = df[i - 1, price_col]
        p_curr = df[i, price_col]
        p_next = df[i + 1, price_col]
        max_neighbor = max(p_prev, p_next)
        min_neighbor = min(p_prev, p_next)

        if p_curr >= 2 * max_neighbor || p_curr <= 0.5 * min_neighbor
            df[i, :keep] = false
        end
    end

    return
end