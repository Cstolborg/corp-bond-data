"""
    data_loader.jl

Data loading functions extracted from src/utils/main.jl (DataLoader module)
"""

using DataFramesMeta
using Dates
using CSV
using Parquet
using SASLib
using XLSX
using ShiftedArrays: lag, lead
using GLM

# Include rating conversions
include("rating_conversions.jl")

# ============================================================================
# TRACE Data Loading
# ============================================================================

"""
    load_trace_intraday(;file="trace_prices.sas7bdat")

Load intraday TRACE trading data from SAS file.
"""
function load_trace_intraday(;file="trace_prices.sas7bdat")
    trace_intraday = @chain begin
        DataFrame(readsas(file, exclude_columns=[:yld_pt, :rpt_side_cd, :cntra_mp_id, :cmsn_trd]))
        rename(:cusip_id=>:cusip, :trd_exctn_dt=>:date, :entrd_vol_qt=>:volume, :rptd_pr=>:price)
        dropmissing([:cusip, :date, :price, :volume])
        @rsubset(!isnan(:price))
        sort([:cusip, :date, :trd_exctn_tm])
        @rtransform!(:cusip6=:cusip[1:6])
    end
    @transform!(trace_intraday, :trd_exctn_tm = :trd_exctn_tm / (3600.))  # Transform time into hourly format
    return trace_intraday
end

"""
    load_trace_daily(;version_="")

Load daily TRACE data from Parquet file.
"""
function load_trace_daily(;version_="", path="data/")
    version_ in ["", "2016"] ? 0 : error(""" version_ must either be an empty string "" for the full dataset or be equal to "2016" """)
    file = "trace_daily"*version_*".pq"
    trace_daily = @chain begin
        DataFrame(read_parquet(path*file))
        @rtransform(:date = Date(:date, dateformat"yyyy-mm-dd"))
        sort([:cusip, :date])
    end
    return trace_daily
end

"""
    load_trace_monthly(;version_="")

Load monthly TRACE data.
"""
function load_trace_monthly(;version_="", path="data/")
    version_ in ["", "2016"] ? 0 : error(""" version_ must either be an empty string "" for the full dataset or be equal to "2016" """)
    file = "trace_month"*version_*".pq"
    df = CSV.read(path*file, DataFrame) |> x->@rtransform!(x, :date = Date(:date, dateformat"yyyy-mm-dd")) |> x->sort(x, [:cusip, :date])
    return df
end

"""
    load_error_cusips(path="data/errors.xlsx")

Load error CUSIPs from Excel file.
"""
function load_error_cusips(path="data/error_checks/errors.xlsx")
    df_trace = DataFrame(XLSX.readtable(path, "TRACE_error"))[:, ["cusip", "trade_date", "error"]]
    dropmissing!(df_trace)
    subset!(df_trace, :error => ByRow(x->x.=="yes"))
    select!(df_trace, :cusip, :trade_date=>(x->lastdayofmonth.(x))=>:date)
    unique!(df_trace)  # Drop duplicates, if any

    df_ice = DataFrame(XLSX.readtable(path, "ICE_errors"))[:, ["cusip", "date", "error"]]
    subset!(df_ice, :error => ByRow(x->x.=="yes"))
    select!(df_ice, :cusip, :date=>(x->lastdayofmonth.(Date.(x)))=>:date)

    errors = vcat(df_trace, df_ice)
    unique!(errors)
    return errors
end

# ============================================================================
# Fama-French and Risk-Free Rate
# ============================================================================

"""
    load_rf(;ff_treasuries=true)

Load risk-free rate (1-month treasury) from Fama-French data.
"""
function load_rf(;ff_treasuries=true, path="data/")
    if ff_treasuries == true
        rf = CSV.read("data/wrds/ff_monthly.csv", DataFrame)
        @rtransform!(rf, :date = Date(:date))
        @select!(rf, :date, :rf)
    end
    return rf
end

"""
    load_ff()

Load Fama-French factors from Kenneth French's Library.
"""
function load_ff()
    df = @chain begin
        CSV.read("data/wrds/ff_monthly.csv", DataFrame)
        @rtransform!(:date = Date(:date))
    end
    return df
end

# ============================================================================
# Trading Dates
# ============================================================================

"""
    load_trade_dates(;with_day_diff=false, trading_days=5)

Load trading dates from Kenneth French's Library.
- with_day_diff: controls format (compressed vs long)
- trading_days: window size for beginning and end of month
"""
function load_trade_dates(;with_day_diff=false, trading_days=5, path="data/")
    df = @chain begin
        CSV.read(path*"wrds/ff_daily.csv", DataFrame)
        select(:date)
        @rtransform(:eom = Dates.lastdayofmonth(:date))
    end

    if with_day_diff == false
        df = @combine(groupby(df, :eom), :first_trading_date=Ref(:date[1:5]), :last_trading_date=Ref(:date[end-trading_days+1:1:end]), :last_trade_date_val=:date[end])  # Compress df to bom and eom
    else
        # Use 3 settlement days before 2017 and 2 after
        # https://www.occ.treas.gov/news-issuances/bulletins/2017/bulletin-2017-22.html
        @transform!(df, :trade_date1 = lag(:date, -3), :trade_date2 = lag(:date, -2))
        @rselect!(df, :date, :eom, :settlement_date = :date < Date(2017,9,5) ? :trade_date1 : :trade_date2)
    end
    return df
end

# ============================================================================
# Bond-Equity Links
# ============================================================================

"""
    load_cusip_permno_gvkey()

Load linking tables connecting CUSIP, PERMNO, and GVKEY.
"""
function load_cusip_permno_gvkey(;path="data/")
    links = @chain begin
        DataFrame(read_parquet(path*"wrds/cusip_permno_gvkey.pq"))
        select(Not([:cusip, :comnam, :shrcd, :exchcd]))
        dropmissing(:ncusip)
        @rtransform(:date = Date(unix2datetime(:date / Int(1e6))),
                    :ncusip_full = :ncusip)
        transform(:ncusip => ByRow(passmissing(x -> x[1:6])) , renamecols=false) # Only use first 6 digits in CUSIP
    end
    return links
end

# ============================================================================
# Market Data
# ============================================================================

"""
    load_BofA_market(;long_term_mkt::Bool=true)

Load Bank of America market index.
- Default is 15-year Corp-Bond index
"""
function load_BofA_market(;long_term_mkt::Bool=true, path="data/")
    if long_term_mkt == true
        df = CSV.read(path*"wrds/BAMLCC8A015PYTRIV.csv", DataFrame; missingstring="") |> x->rename(x, :observation_date=>:date, :BAMLCC8A015PYTRIV => :price)
    else
        df = CSV.read(path*"FRED/BAMLCC0A0CMTRIV.csv", DataFrame; missingstring=".") |> x->rename(x, :observation_date=>:date, :BAMLCC0A0CMTRIV => :price)
        @rtransform!(df, :price = ifelse(:price == "", missing, :price))
        dropmissing!(df, :price)
        @transform!(df, :price = parse.(Float64, :price))
    end

    df = @chain df begin
        @subset(:price .!= 0., .!ismissing.(:price))  # remove missing obs
        @transform(:eom = lastdayofmonth.(:date))
        @combine(groupby(_, :eom), :date=:date[end], :price=:price[end])
        transform(:price => (x->lag(x, 1)) => :price_lag)
        @rselect(:date = :eom, :ret_eom = :price / :price_lag - 1.)
        dropmissing
    end
    return df
end

"""
    load_long_term_gov()

Load long-term government (10-year treasury) return from CRSPA.TFZ_MTH_BP in WRDS.
"""
function load_long_term_gov(;path="data/")
    df = @chain begin
        DataFrame(readsas(path*"wrds/fama_treasury.sas7bdat", exclude_columns=[:KYTREASNOX])) |> x->rename(x, :TMEWRETD=>:ret_eom)
        dropmissing()
        @subset(.!isnan.(:ret_eom))
        @rtransform(:date = lastdayofmonth(Date(:date)))
        select(:date, :ret_eom, :)  # reorder columns
    end
    return df
end

"""
    load_vix()

Load VIX index from FRED (https://fred.stlouisfed.org/series/VIXCLS#0).
"""
function load_vix(;path="data/")
    vix = CSV.read(path*"wrds/VIXCLS.csv", DataFrame) |> x->rename(x, :observation_date=>:date, :VIXCLS =>:price)
    @transform!(vix, :date = lastdayofmonth.(:date))
    vix = @combine(groupby(vix, :date), :date=:date[end], :price=:price[end])

    vix.price_lag = lag(vix.price, 1)
    vix = dropmissing(vix)
    vix.vix = lm(@formula(price~1+price_lag), vix) |> residuals
    vix.vix_lag = lag(vix.vix, 1)
    vix = dropmissing(vix)
    return select(vix, :date, :vix, :vix_lag)
end

# ============================================================================
# Mergent FISD
# ============================================================================

"""
    load_mergent()

Load Mergent FISD bond characteristics.
"""
function load_mergent(;path="data/")
    df = @chain begin
        CSV.read(path*"mergent/fisd_issue.csv.gz", DataFrame)
        @rselect(:cusip6=:ISSUER_CUSIP, :cusip8=:COMPLETE_CUSIP[1:8], :cusip=:COMPLETE_CUSIP, :TICKER, :name=:CUSIP_NAME,
                :SECURITY_LEVEL, :INDUSTRY_GROUP, :INDUSTRY_CODE, :SIC_CODE, :BOND_TYPE, :COUPON_TYPE, :COUPON,
                :OFFERING_YIELD, :INTEREST_FREQUENCY, :CONVERTIBLE, :PUTABLE,
                :OFFERING_AMT, :OFFERING_PRICE, :PRINCIPAL_AMT)
        rename(lowercase, _)
    end
    return df
end
