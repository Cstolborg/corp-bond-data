"""
    compute_bond_returns(trace_month, mergent, defaults, ratings, amt_out, rf; kwargs...)

Main function to compute bond returns with accrued interest, ratings, and other characteristics.

This function:
1. Merges TRACE monthly prices with FISD characteristics
2. Adds accrued interest and coupon payments
3. Computes returns: (P_t + AI_t + C_t) / (P_t-1 + AI_t-1) - 1
4. Adds credit ratings
5. Filters bonds (removes convertibles, non-standard types)
6. Computes excess returns over risk-free rate
7. Adds equity links (PERMNO)

# Arguments
- `trace_month`: Monthly TRACE pricing data
- `mergent`: FISD bond characteristics
- `defaults`: Default dates
- `ratings`: Time-varying credit ratings
- `amt_out`: Amount outstanding data
- `rf`: Risk-free rate data

# Keyword Arguments
- `calendar_lag`: Use calendar lags vs observation lags
- `min_tmt`: Minimum time to maturity (default: 1 year)
- `keep_def_rets`: Keep defaulted bond returns
- `remove_errors`: Remove manually identified errors

# Returns
DataFrame with bond returns and characteristics
"""
function compute_bond_returns(trace_month, mergent, defaults, ratings, amt_out, rf;
                              calendar_lag::Bool=true, use_bom_prices::Bool=false, acc_interest_method::String="R-package",
                              min_tmt::Number=1., delist_ret::Bool=true, delist_coupacc::Bool=false, keep_def_rets::Bool=false,
                              remove_errors::Bool=false, add_filters::Bool=false, yield_file=nothing)
    
    df = trace_month
    #@subset!(df, :date .<= end_date)
    calendar_lag == true ? df = calendar_fill(df, date_col=:date, n_expand=0) : nothing # Expand trace dataset to have observation each month per cusip - useful for getting accrued interest lagged

    transform!(groupby(df, :cusip), [:price_eom] .=> lag)
    @rtransform!(df, :ret_eom_default = :price_eom / :price_eom_lag - 1.)  # Compute here so I can count number of returns
    println("All Returns " , nrow(dropmissing(df, :ret_eom_default)))


    # Add bond info from mergent fisd
    df = innerjoin(df, mergent, on=[:cusip])
    transform!(df, :coupon => ByRow(x->replace_nans(x, replace_val=0.)) => :coupon)
    
    if (yield_file == nothing) || (typeof(yield_file) == String && yield_file != "30/360")
        yield_file = "data/output/risk_measures_trace.csv"
        df = add_yields(df, yield_file=yield_file)  # Yields + accrued interest
        df = get_coupon_schedule(df; return_coups=false)  # Coupamt
    elseif yield_file == "30/360"
        df = add_accrued_interest(df, acc_interest_method=acc_interest_method) # Accrued interest
    end
    df = add_amount_outstanding(df, amt_out)  # Amount outstanding

    # Returns & Market values
    sort!(df, [:cusip, :date])
    @rtransform!(df, :MV = :amount_outstanding * :principal * :price_eom / 100.)
    transform!(groupby(df, :cusip), [:MV, :coupacc] .=> lag)

    if use_bom_prices == true  # Prefer last month prices - if missing use beginning of month prices
    @rtransform!(df, :price_eom_lag = coalesce(:price_eom_lag, :price_bom), 
                :MV_lag = coalesce(:MV_lag, :amount_outstanding * :principal * :price_bom / 100.))  # If MV_lag is missing try using beg. of month prices
    end
    @rtransform!(df, :ret_eom = (:price_eom + :coupamt + :coupacc) / (:price_eom_lag + :coupacc_lag) - 1.)

    df = add_ratings(df, ratings)  # Add ratings
    println("Returns after merging with FISD " , nrow(dropmissing(df, :ret_eom_default)))
    @rsubset!(df, :coupon_type in ["F", "Z"])
    println("Remove Variable rate " ,nrow(dropmissing(df, :ret_eom_default)))

    # Drop missing values and errors
    if remove_errors == true
        error_obs = DataLoader.load_error_cusips()
        df = antijoin(df, error_obs, on=[:cusip, :date])  # Delete error observations
        println("Remove errors " ,nrow(dropmissing(df, :ret_eom_default)))
    end
    if add_filters == true
        filter_bonds!(df)
    end

    # Default returns  - if a bond defaults and has no return impute delisting returns - use same numbers as WRDS and depends on whether bond is HY or IG
    transform!(groupby(df, :cusip), :ret_eom=>lag=>:ret_eom_lag)
    df = add_default_returns(df, defaults; delist_coupacc=delist_coupacc, delist_ret=delist_ret)
    
    transform!(df, [:maturity, :date] => ByRow((mat, date)-> Dates.value(mat-date)/365.) => :tmt )  # Time to maturity
    df = df[df.tmt .>= min_tmt, :]
    println("Remove tmt < 1 " ,nrow(dropmissing(df, :ret_eom_default)))

    # Compute excess returns
    df = leftjoin(df, rf, on=:date)
    df.ret_exc .= df.ret_eom .- df.rf
    df = dropmissing(df, [:price_eom, :MV])
    subset!(df, [:ret_exc, :MV] .=> ByRow(x->!(x isa Number && isnan(x))), :MV => ByRow(x->x!=0.))
    transform!(groupby(df, :cusip), :ret_exc => lead=>:ret_exc_lead, :MV=>lead=>:MV_lead, :ret_exc=>(x->lead(x, 2))=>:ret_exc_lead2)

    println("Remove MV = 0 " ,nrow(dropmissing(df, :ret_eom_default)))

    if keep_def_rets == false
        subset!(df, [:default_ind, :post_default] .=> (x-> x .== false))  # Remove defaulted returns
        println("Remove defaulted " ,nrow(dropmissing(df, :ret_eom_default)))
        dropmissing!(df, :rating_num)
        subset!(df, :rating_num=> ByRow(x-> 1. <= x .<=22.))  # Remove bonds not rated
        #subset!(df, :rating_num=> ByRow(x-> x .<22.))  # Remove values with rating at or above 22 (D)

        println("Remove not rated " ,nrow(dropmissing(df, :ret_eom_default)))
    end

    @rtransform!(df, :cusip6=:cusip[1:6])
    df = add_permno(df)

    sort!(df, [:cusip, :date])
    #transform!(df, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating)  # Convert rating to IG+, IG- and SG
    select!(df, :cusip, :date, :price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :MV, :tmt, :name, :)  # Reorder terms

    #println("No. obs with yields $(nrow(dropmissing(df, :yield))) out of $(nrow(dropmissing(df, :price_eom)))")
    return df
end

compute_bond_returns(trace_month, fisd, rf; kwargs...) =  compute_bond_returns(trace_month, fisd.mergent, fisd.defaults, fisd.ratings, fisd.amt_out, rf; kwargs...)

function filter_bonds!(df; print_obs=false)
    subset!(df, :convertible => x->x.=="N", :bond_type=> ByRow(x->x != "CCOV"))  # Remove convertible
    print_obs || println("Remove Convertible " ,nrow(dropmissing(df, :ret_eom_default)))

    # Delete bonds that do not have principal 1000
    subset!(df, :principal=>x->x.==1000)
    print_obs || println("Remove Bonds that do not have principal 1000 " ,nrow(dropmissing(df, :ret_eom_default)))

    subset!(df, :bond_type=> ByRow(x->x != "TPCS"))
    print_obs || println("Remove TPCS " ,nrow(dropmissing(df, :ret_eom_default)))

    subset!(df, :bond_type=> ByRow(x->x != "CPIK"))
    print_obs || println("Remove CPIK " ,nrow(dropmissing(df, :ret_eom_default)))

    subset!(df, :bond_type=> ByRow(x->x != "CPAS"))
    print_obs || println("Remove CPAS " ,nrow(dropmissing(df, :ret_eom_default)))

    subset!(df, :issue_name=>ByRow(x-> !( occursin("EQUITY-LINKED", x) || occursin("EQUITY LINKED", x) || occursin("INDEX-LINKED", x)  ) ) )
    print_obs || println("Remove equity-linked " ,nrow(dropmissing(df, :ret_eom_default)))

    subset!(df, :bond_type=>ByRow(x->x ∉ ["FGOV", "ADEB", "ASPZ", "PS", "USBD", "USNT", "AMTN", "USSI", "USTC", "USSP", "MBS", "TXMU"]))
    print_obs || println("Remove Non-US Non-Corporate Bonds ", nrow(dropmissing(df, :ret_eom_default)))

    dropmissing!(df, :rating_num)
    subset!(df, :rating_num=> ByRow(x-> 1. <= x .<=22.))  # Remove bonds not rated
    print_obs || println("Remove not-rated " ,nrow(dropmissing(df, :ret_eom_default)))
end

""" Adds yield, accured interest, duration and convexity from R-package bondvaluation """
function add_yields(df; yield_file="data/output/risk_measures_trace.csv")
    yields = CSV.read(yield_file, DataFrame)
    df = leftjoin(df, yields, on=[:date, :cusip])
    rename!(df, :coupacc1=>:coupacc)

    return df
end

""" Compute coupamt each month, if any according to schedule from BondValuation R-package """
function get_coupon_schedule(df; return_coups=false, date_path="data/output/dates_trace.csv")
    dates = CSV.read(date_path, DataFrame) |> x->@transform(x, :eom = lastdayofmonth.(:CoupDates))

    # Match on settlement date - if settlement is before CoupDates
    df_tmp = dropmissing(df, [:price_eom])
    @rtransform!(df_tmp, :settlement_date_eom = lastdayofmonth(:settlement_date) )
    coups = innerjoin(df_tmp[!, [:cusip, :date, :settlement_date, :settlement_date_eom, :interest_frequency]], dates, on=[:cusip, :settlement_date_eom=>:eom])
    @subset!(coups, :settlement_date .>= :CoupDates)
    select!(coups, :cusip, :date, :CoupPayments)

    # Take those coups not matched on settlement_date
    coups2 = innerjoin(df_tmp[!, [:cusip, :date, :settlement_date, :settlement_date_eom]], dates, on=[:cusip, :date=>:eom])
    #tmp2 = antijoin(tmp2, coups, on=[:cusip, :date])

    # Filter those obs away where settlement day of previous month is above CoupDates
    trade_days = DataLoader.load_trade_dates(with_day_diff=true) |> x->@subset(groupby(x, :eom), :date.==maximum(:date))
    @rselect!(trade_days, :date = lastdayofmonth(:date + Month(1)), :settlement_date_lag=:settlement_date)
    coups2 = innerjoin(coups2, trade_days, on=:date)
    @subset!(coups2, :settlement_date_lag .< :CoupDates)
    select!(coups2, :cusip, :date, :CoupPayments)


    #vcat(coups,tmp2)
    #unique(vcat(coups,tmp2), [:cusip, :date])
    coups = unique(vcat(coups2, coups), [:cusip, :date])
    #nrow(unique(coups, [:cusip, :date])) == nrow(coups) || error("There are two different coupons in coups and coups2")

    if return_coups==true
        return coups
    end
    df = leftjoin(df, coups, on=[:cusip, :date])
    @rtransform!(df, :coupamt=coalesce(:CoupPayments, 0.))
    select!(df, Not([:CoupPayments]))
    return df
end

function add_amount_outstanding(df, amt_out)
    amt_out = innerjoin(df[:, [:date, :cusip]], amt_out, on=:cusip)
    @rsubset!(amt_out, :date_start <= :date < :date_end)
    select!(amt_out, Not([:date_start, :date_end]))
    df = leftjoin(df, amt_out[!, [:date, :cusip, :amount_outstanding]], on=[:cusip, :date])
    return df
end

"""
    add_ratings(df, ratings)

Add time-varying credit ratings to bond dataset.
"""
function add_ratings(df, ratings)
    ratings = innerjoin(df[:, [:date, :cusip]], ratings, on=[:cusip])
    ratings = @rsubset(ratings, :date_start <= :date < :date_end) |> x-> select(x, Not([:date_start, :date_end]))
    df = leftjoin(df, ratings[!, [:date, :cusip, :rating_num, :default_date_rating]], on=[:cusip, :date])  # Changes order of rows in data
    transform!(df, :rating_num=>ByRow(x->ceil(x)), renamecols=false)
    return df
end

function add_default_returns(df, defaults; delist_coupacc=false, delist_ret=true)
    # Default returns  - if a bond defaults and has no return impute delisting returns - use same numbers as WRDS and depends on whether bond is HY or IG
    leftjoin!(df, defaults, on=:issue_id)
    transform!(df, [:default_date_rating, :default_date]=>ByRow((ddr,dd)->minimum(skipmissing([ddr,dd]), init=Date(2100,1,31)))=>:default_date)
    @rtransform!(df, :default_date_eom = lastdayofmonth(:default_date))
    @rtransform!(df, :default_ind = :default_date_eom == :date, :post_default = :default_date_eom < :date, :is_highyield = :rating_num > 10.)  # default indicator, post-default indicator and high-yield indicator
    df.default_ind = replace(df.default_ind, missing => false)
    df.post_default = replace(df.post_default, missing => false)
    
    if delist_coupacc == false  # Remove accrued interest from returns when bond is in default
        @rtransform!(df, :ret_eom = ifelse(!ismissing(:post_default) && :post_default, :ret_eom_default, :ret_eom)) 
    end
    if delist_ret == true
        tmp = @subset(df, :default_ind .==true) |> x->dropmissing(x, [:ret_eom, :ret_eom_lag])
        @select!(tmp, :cusip, :date, :rating_num, :price_eom, :ret_eom, :ret_eom_lag, :default_ret=((1. .+ :ret_eom_lag) .* (1. .+ :ret_eom) .-1. ))
        sg_def = @subset(tmp, :rating_num .>=11) |> x-> mean(x.default_ret)  # SG
        if_def = @subset(tmp, :rating_num .<11) |> x-> mean(dropmissing(x, :default_ret).ret_eom)  # IG
        all_def = mean(dropmissing(tmp, :default_ret).ret_eom)  # All
        println("Delisting returns: IG=$(round(if_def, digits=3)) -- SG=$(round(sg_def, digits=3)) -- ALL=$(round(all_def, digits=3))")
        
        @rtransform!(df, :ret_eom = ifelse(ismissing(:ret_eom) && !ismissing(:default_ind) && :default_ind,  # If missing return and is in default
                                    all_def,
                                    :ret_eom) )   
    end
    return df
end

""" Add accrued interest to coupon-paying bonds """
function add_accrued_interest(df; acc_interest_method="R-package")
    #df.coupmonth = @. (year(df.date) - year(df.first_interest_date))*12 + month(df.date) - month(df.first_interest_date)  # Coupon month where month 0 is first_interest_date
    #@transform! df @byrow @passmissing :settlement_date = :date + Day(:trade_date2)
    
    # Coupon month: Counter for which months coupons are paid out in
    # If the day of settlement is before coupon payment, use settlement date for calc, otherwise use :date
    dropmissing!(df, [:first_interest_date, :interest_frequency, :settlement_date])
    @rtransform!(df, :coupmonth = ifelse(day(:settlement_date) > day(:first_interest_date),
                                        (year(:settlement_date) - year(:first_interest_date))*12 + month(:settlement_date) - month(:first_interest_date),
                                        (year(:date) - year(:first_interest_date))*12 + month(:date) - month(:first_interest_date))
                                        )
    df_c = @subset(df, :interest_frequency .!= 0)  # data with only coupon-paying bonds
    @rtransform!(df_c, :last_coupon = :first_interest_date + Month(floor(:coupmonth * :interest_frequency /12.) *12. /:interest_frequency))  # floor function to standardize dates within interst periods. ))
    @rtransform!(df_c, :coupamt = ifelse(mod(:coupmonth, 12/:interest_frequency) == 0 && :interest_frequency != 0, :coupon / Float64(:interest_frequency), 0.) )  # Amount payed in coupon if any

    # Handle offering month and months before first interest date
    @rtransform!(df_c, :coupamt = ifelse(:coupmonth < 0, 0., :coupamt ))

    if  acc_interest_method == "actual/actual"
        @rtransform!(df_c, :days_last_coup = Dates.value(:date - :last_coupon) )
        @rtransform!(df_c, :coupacc = :coupon * :days_last_coup / 365.  )
    elseif acc_interest_method == "30/360"
        @rtransform!(df_c, :days_last_coup = mod(:coupmonth, 12/:interest_frequency)*30. + (30. - min(Float64(day(:first_interest_date)), 30.)) )  # Days since last coupon - assume max 30 days in month       
        @rtransform!(df_c, :days_last_coup = ifelse(year(:date)==year(:offering_date) && month(:date)==month(:offering_date) , (30. - min(Float64(day(:offering_date)), 30.)), :days_last_coup ))
        #@rtransform!(df_c, :days_last_coup = :days_last_coup + :trade_date2)  # Adjust for settlement-date
        @rtransform!(df_c, :coupacc = :coupon * :days_last_coup / 360.  )
    elseif acc_interest_method == "R-package"
        rename!(df_c, :coupacc1=>:coupacc)
        rename!(df, :coupacc1=>:coupacc)
    else
        error("""acc_interest_method has to be in ["R-package", "30/360", "actual/actual"] """)
    end

    @subset!(df, :interest_frequency .== 0)
    df = vcat(df_c, df, cols=:union)  # Concatenate zero coupon bonds back onto dataframe
    transform!(df, [:coupamt] .=> ByRow(x->replace_nans.(x; replace_val=0.)), renamecols=false)  # Replace NaN and missing with zero
    transform!(df, [:coupacc] .=> ByRow(x->(!ismissing(x) && (x isa Number && isnan(x))) ? 0. : x ), renamecols=false)  # Replace NaN with zero
    return df
end