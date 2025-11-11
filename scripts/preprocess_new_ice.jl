using DataFramesMeta, Dates, CSV, Parquet
using Statistics
using StatsPlots
using SASLib
using ShiftedArrays: lead, lag
gr(size=(1200, 700))
Plots.scalefontsizes()
Plots.scalefontsizes(1.2)

include("../src/main.jl")

df = CSV.read("data/ice_new/ICE_GI00.csv", DataFrame)
#CSV.write("data/ice_new/ice_sample.csv", df[1:1000_000, :])
select!(df, 2, 4:6, 8:25)
rename!(lowercase, df)
rename!(df, :as_of_date=>:date)
df.eom = lastdayofmonth.(df.date)

@subset!(df, :iso_currency.=="USD")
@subset!(df, :coupon_type.!="Floating")
dropmissing!(df, :price)  # No return if no price


# Compute illiquidity
function illiq_ice(df)
    tmp = copy(select(df, :cusip, :eom, :price))
    transform!(tmp, [:price]=>(p->log.(p)-lag(log.(p)) )=>:log_price)
    @transform!(groupby(tmp, [:cusip, :eom]), :log_price_lag = lag(:log_price, 1))  # NB! no requirement on day diff between log returns
    subset!(groupby(tmp, [:cusip, :eom]), [:log_price, :log_price_lag]=>ByRow((p, p_lag)->!ismissing(p)&&!ismissing(p_lag)))
    transform!(groupby(tmp, [:cusip, :eom]), :log_price=>(p->length(p) >= 5)=>:enough_price_pairs)
    @subset!(tmp, :enough_price_pairs.==true)

    illiq = combine(groupby(tmp, [:cusip, :eom]), [:log_price, :log_price_lag]=>((p, p_lag)-> -1. * cov(p, p_lag))=>:illiq)
    CSV.write("data/ice_new/illiq.csv", illiq)
    tmp = nothing
    return illiq
end
illiq = illiq_ice(df)

# Convert to monthly by taking last observation each month
df = combine(groupby(df, [:eom, :cusip]), last)
sort!(df, [:cusip, :eom])

@transform!(groupby(df, :cusip), :ret_eom=:trr_index_val_loc ./ lag(:trr_index_val_loc) .- 1.0)
@rtransform!(df, :rating_num=ice_alphabet_to_numerical[:rating])
@subset!(df, 1. .<= :rating_num .<= 22.)
transform!(df, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating)
select!(df, 
    :cusip, :eom, :ticker, :price, :ret_eom, :rating, :rating_num,
    :macaulay_dur, :oas, :yld_to_maturity, :current_coupon, :maturity_date, :issue_date, :
)

@transform!(df, :date = lastdayofmonth.(:date))
rename!(df, :cusip=>:cusip8, :price=>:price_eom, :macaulay_dur=>:duration, :yld_to_maturity=>:yield, :oas=>:yield_spread, :current_coupon=>:coupon,
            :maturity_date=>:maturity, :issue_date=>:offering_date, :accrued_interest=>:coupacc
)
@rsubset!(df, :date.>=:offering_date)  # Some cusips have offering dates years after the day they are trading
transform!(df, [:maturity, :date] => ByRow((mat, date)-> Dates.value(mat-date)/365.) => :tmt )  # Time to maturity
@subset!(df, :tmt .>= 1.0)


CSV.write("data/ice_new/ice_month_semiraw.csv", df)

#### DONE WITH DAILY DATA #####
#### MONTHLY BELOW #####

rf = DataLoader.load_rf()
fisd = Preprocess.Fisd()

df = CSV.read("data/ice_new/ice_month_semiraw.csv", DataFrame)
@subset!(df, :date .<= Date(2023, 12, 31))



# Add FISD information and calendar fill
cols_to_drop_mergent = [:coupon, :coupon_type, :offering_date, :maturity]
transform!(df, cols_to_drop_mergent .=> identity .=> (x->x*"_raw"))
select!(df, Not(cols_to_drop_mergent))

df = innerjoin(df, fisd.mergent, on=:cusip8)
df = Preprocess.add_amount_outstanding(df, fisd.amt_out)
transform!(df, [[col, Symbol(string(col)*"_raw")] => ByRow((x, x_raw)->coalesce(x, x_raw))=>col for col in cols_to_drop_mergent])
select!(df, Not(string.(cols_to_drop_mergent).*"_raw"))

sort!(df, [:cusip8, :date])    
@rtransform!(df, :MV = :amount_outstanding * :principal * :price_eom / 100.)
transform!(groupby(df, :cusip8), [:price_eom, :MV, :coupacc] .=> lag)

@rsubset!(df, :coupon_type in ["F", "Z"])

Preprocess.filter_bonds!(df; is_warga_data=true)

# Add settlement date, interest frequency - NB! This is not information from documenation or other sources so basic values are just assumed
trade_dates = DataLoader.load_trade_dates(with_day_diff=false)
trade_dates_diff = DataLoader.load_trade_dates(with_day_diff=true)[!, Not(:eom)]
leftjoin!(df, trade_dates[!, [:eom, :last_trade_date_val]], on=:date=>:eom)
leftjoin!(df, trade_dates_diff, on=[:last_trade_date_val => :date])


# Add permno, gvkey, risk-free rate and compute excess returns
leftjoin!(df, rf, on=:date)
df.ret_exc .= df.ret_eom .- df.rf 
dropmissing!(df, [:price_eom, :MV])
subset!(df, [:ret_exc, :MV] .=> ByRow(x->!(x isa Number && isnan(x))), :MV => ByRow(x->x!=0.))
transform!(groupby(df, :cusip), :ret_exc => lead=>:ret_exc_lead, :MV=>lead=>:MV_lead, :ret_exc=>(x->lead(x, 2))=>:ret_exc_lead2)

# Add permno using link tables for before and after trace
df1 = @subset(df, :date.<=Date(2002, 7, 31)) |> x-> add_permno(x; link_period="warga")
df2 = @subset(df, :date.>Date(2002, 7, 31)) |> x-> add_permno(x; link_period="trace")
df = vcat(df1, df2); df1 = df2 = nothing

@rtransform!(df, :cusip6 = :cusip8[1:6]*"10")
sort!(df, [:cusip, :date])

select!(df, :cusip, :date, :price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :MV, :tmt, :name, :)  # Reorder terms
CSV.write("data/ice_new/ice_monthly.csv", df)