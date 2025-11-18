using DataFramesMeta, Dates, CSV, Parquet
using Statistics
using StatsPlots
using SASLib
using ShiftedArrays: lead, lag
gr(size=(1200, 700))
Plots.scalefontsizes()
Plots.scalefontsizes(1.2)

include("../src/main.jl")

PATH = "C:/Users/chris/CBS Dropbox/Christian Stolborg/Corporate Bond Replication/data/data_to_share/"




tmp = CSV.read("./data/data_to_share/firm_returns.csv", DataFrame)


# BOND + FIRM returns
cols_bonds = ["date", "cusip", "permno", "market_value", "ret_exc_lead", "ret_texc_lead", "yield", "duration", "rating_group"]
cols_firms = ["date", "permno", "market_value", "ret_exc_lead", "ret_texc_lead", "yield", "duration", "rating_group"]

numcols = [:price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :ret_exc_lead2, :ret_texc_lead, :value, :rating_num, :MV, :amount_outstanding, :MV_lag, :MV_lead, :duration, :duration_lead, :tmt, :convexity, :bond_age_pct, :bm, :yield_spread, :yield]
bonds = CSV.read("scripts/scientific_replication/data/bonds_full.csv", DataFrame)
firms = Preprocess.compute_firm_ret(bonds, numcols; firm_id=:permno, duration_adjust=true)

for (df, cols) in zip([bonds, firms], [cols_bonds, cols_firms])
    @rtransform!(df, :rating_group=rating_conversion[round(:rating_num)])
    @rtransform!(df, :rating_group=rating_conversion[round(:rating_num)])
    rename!(df, "MV"=>"market_value")
    select!(df, cols)
end

@df combine(groupby(bonds, :date; sort=true), nrow) plot(:date, :nrow, label="Bonds")
@df combine(groupby(firms, :date; sort=true), nrow) plot!(:date, :nrow, label="Firms")

CSV.write(PATH*"bond_returns.csv", bonds)
CSV.write(PATH*"firm_returns.csv", firms)

# EQUITY RETURNS
lms1 = CSV.read("scripts/scientific_replication/data/equity_factor_returns.csv", DataFrame)
lms11 = unstack(lms1, :date, :characteristic, :value)

cluster = CSV.read("scripts/scientific_replication/data/equity_cluster_factor_returns.csv", DataFrame)
cluster1 = unstack(cluster, :date, :cluster, :value)

CSV.write(PATH*"equity_factor_returns_all.csv", lms11)
CSV.write(PATH*"equity_factor_returns_cluster.csv", cluster1)


# LINK tables
link_trace = DataFrame(readsas("data/wrds/bondcrsp_link.sas7bdat")) |> x->select(x, 1:3, 8:9) |> x-> rename(lowercase, x)
link_trace.source .= "trace"
link_warga = CSV.read("data/BondEqLink.csv", DataFrame) |> x-> rename(lowercase, x)
select!(link_warga, "full_cusip"=>identity=>"cusip", "permno", "link_startdt", "link_enddt")
transform!(link_warga, [:link_startdt, :link_enddt].=>ByRow(x->Date(string(x), DateFormat("yyyymmdd"))), renamecols=false)
link_warga.source .= "warga"

links = vcat(link_trace[!, Not(:permco)], link_warga)

CSV.write(PATH*"bond_equity_link.csv", links)



# FACTOR RETURNS

signals_full = CSV.read("scripts/scientific_replication/data/signals_warga_trace.csv", DataFrame) |> x->transform!(x, Symbol("Credit Rating")=>ByRow(x->rating_conversion[round(x)])=>:rating) #|> x->@subset(x, :date.>=Date(1985,2,28))
fsignals_full = CSV.read("scripts/scientific_replication/data/fsignal_warga_trace.csv", DataFrame) |> x->transform!(x, Symbol("Credit Rating")=>ByRow(x->rating_conversion[round(x)])=>:rating) #|> x->@subset(x, :date.>=Date(1985,2,28))
factor_regressors = CSV.read("scripts/scientific_replication/data/factor_regressors_warga_trace.csv", DataFrame)
factor_regressors_full = factor_regressors

@subset!(signals_full, :date .>= Date(1985, 2, 28))
@subset!(fsignals_full, :date .>= Date(1985, 2, 28))

pfs_b, ret, ret1 = Pfs.factor_pipeline(signals_full, factor_regressors; double_sort=:rating, N_sorts=3, x=["market", "term"], get_returns=true)


signals_firms = copy(signals_full)
df1 = @subset(signals_firms, :date.<=Date(2002, 7, 31)) |> x-> add_permno(x; link_period="warga")
df2 = @subset(signals_firms, :date.>Date(2002, 7, 31)) |> x-> add_permno(x; link_period="trace")
signals_firms = vcat(df1, df2, cols=:union); df1 = df2 = nothing
select!(signals_firms, Not("permco"))
dropmissing!(signals_firms, :permno)
@rtransform!(signals_firms, :permno_rating  = string(Int(:permno))*"-"*:rating)
select!(signals_firms, :cusip, :permno, :permno_rating, :date, :)
pfs_f, ret_f, ret1_f = Pfs.factor_pipeline(signals_firms[!, Not("Equity Momentum")], factor_regressors_full; double_sort=:permno_rating, N_sorts=3, min_ret=1, get_returns=true)
rename!((x->x*"-within-firm"), ret_f)
rename!(ret_f, "date-within-firm" => "date")

ret_f = coalesce.(ret_f, 0)
ret = coalesce.(ret, 0)


_, frets, _ = Pfs.factor_pipeline(fsignals_full, factor_regressors_full; get_returns=true, double_sort=:rating, N_sorts=3)


CSV.write(PATH*"Data on Corporate Bond Factors/bond_factors.csv", ret)
CSV.write(PATH*"Data on Corporate Bond Factors/firm_factors.csv", frets)
CSV.write(PATH*"Data on Corporate Bond Factors/bond_factors_within_firm.csv", ret_f)

# FACTOR model
rets = leftjoin(ret, lms11, on=:date) |> x-> leftjoin(x, factor_regressors_full[!, [:date, :market, :term]], on=:date)
leftjoin!(rets, ret_f, on=:date)
rets.date = Dates.Date.(rets.date)  # Ensure date is of type Date
@subset!(rets, :date.>=Date(1985, 3, 31))  # Start date for factor models to ensure equity mom has non-missing values
dropmissing!(rets)

select!(rets, "date", "Value-within-firm", "ret_6_1", "capx_gr1", "market", "Bond Age", "Market Value*", "term")

CSV.write(PATH*"Data on Corporate Bond Factors/factor_model.csv", rets)