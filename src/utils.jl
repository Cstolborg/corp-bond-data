"""
    utils.jl

Utility functions extracted from src/utils/functions.jl
"""

using DataFrames
using DataFramesMeta
using Dates
using SASLib
using CSV
using ShiftedArrays: lag

# ============================================================================
# Data Transformation Functions
# ============================================================================

"""
    replace_nans(x; replace_val=missing)

Replace NaN and Inf values with specified replacement value (default: missing).
"""
replace_nans(x; replace_val=missing) = ismissing(x) || (x isa Number && (isnan(x) | isinf(x))) ? replace_val : x

"""
    replace_nans(df::AbstractDataFrame; replace_val=missing)

Replace NaN and Inf values in all columns of DataFrame.
"""
replace_nans(df::AbstractDataFrame; replace_val=missing) = transform(df, All() .=> ByRow(x->replace_nans(x; replace_val=replace_val)), renamecols=false)

"""
    replace_nans!(df::AbstractDataFrame; replace_val=missing)

In-place version of replace_nans for DataFrame.
"""
replace_nans!(df::AbstractDataFrame; replace_val=missing) = transform!(df, All() .=> ByRow(x->replace_nans(x; replace_val=replace_val)), renamecols=false)

replace_nans_zero(x; replace_val=missing) = ismissing(x) || (x isa Number && isnan(x)) || (x isa Number && iszero(x)) ? replace_val : x  # Replace NaN with replace_val
replace_nans_zero(df::AbstractDataFrame; replace_val=missing) = transform(df, All() .=> ByRow(x->replace_nans_zero(x; replace_val=replace_val)), renamecols=false)


"""
    ffill(v)

Forward fill missing values in vector.
"""
ffill(v) = v[accumulate(max, [i*!ismissing(v[i]) for i in 1:length(v)], init=1)]

"""
    bfill(v)

Backward fill missing values in vector.
"""
bfill(v) = reverse(v) |> ffill |> reverse

# ============================================================================
# Date Conversion Functions
# ============================================================================

"""
    date_to_year_month_day!(df)

Transform date column into separate year, month, and day columns.
Useful for Parquet serialization.
"""
function date_to_year_month_day!(df)
    transform!(df, :date => (x->year.(x)) => :year,
                   :date => (x->month.(x)) => :month,
                   :date => (x->day.(x)) => :day)
    select!(df, Not(:date))
end

"""
    year_month_day_to_date!(df)

Parse year, month, and day columns back into Date format.
"""
function year_month_day_to_date!(df)
    transform!(df, [:year, :month, :day] => ByRow((y,m,d)->Date(y,m,d))=>:date)
    select!(df, :cusip, :date, Not([:year, :month, :day]))
end

# ============================================================================
# DataFrame Expansion and Filling
# ============================================================================

"""
    calendar_fill(df; date_col=:date, level=:cusip, n_expand=0)

Expand DataFrame by date so that every month has an observation for each entity.
Creates a complete panel by filling in missing months.

# Arguments
- `df`: Input DataFrame
- `date_col`: Name of date column (default: :date)
- `level`: Grouping variable (default: :cusip)
- `n_expand`: Number of months to expand beyond observed range (default: 0)

# Returns
DataFrame with complete monthly panel, missing values for unobserved periods
"""
function calendar_fill(df; date_col=:date, level=:cusip, n_expand=0)
    if n_expand == 0
        df = combine(groupby(df, level)) do sdf
            ref_df = DataFrame(date_col => (minimum(sdf[!, date_col])):Month(1):maximum(sdf[!, date_col]))
            transform!(ref_df, date_col => (x->lastdayofmonth.(x)) => date_col, renamecols=false)
            leftjoin!(ref_df, select(sdf, Not(level)), on=date_col)
        end
    else
        df = combine(groupby(df, level)) do sdf
            ref_df = DataFrame(date_col => (minimum(sdf[!, date_col])-Month(n_expand)):Month(1):(maximum(sdf[!, date_col])+Month(n_expand)) )
            transform!(ref_df, date_col => (x->lastdayofmonth.(x)) => date_col, renamecols=false)
            leftjoin!(ref_df, select(sdf, Not(level)), on=date_col)
        end
    end
    return df
end

# ============================================================================
# Linking Functions
# ============================================================================

"""
    dropduplicates(df::AbstractDataFrame, cols; keep = :first)

Drop duplicate rows from DataFrame based on specified columns.

# Arguments
- `df`: Input DataFrame
- `cols`: Columns to check for duplicates
- `keep`: Which duplicate to keep (:first, :last, or :none)

# Returns
DataFrame with duplicates removed
"""
function dropduplicates(df::AbstractDataFrame, cols; keep = :first)
    keep in [:first, :last, :none] || error("keep parameter should be in [:first, :last, :none]")
    combine(groupby(df, cols)) do sdf
        if nrow(sdf) == 1
            sdf
        elseif keep == :none
            DataFrame()
        else
            DataFrame(
              filter(
                r->rownumber(r)==(keep == :first ? 1 : nrow(sdf)),
                eachrow(sdf)
              )
            )
        end
    end
end

"""
    add_permno(df; link_period="trace")

Use WRDS linking table to add PERMNO to bond database.

Links bond CUSIPs to equity PERMNOs using time-varying link tables.
Handles cases where CUSIPs map to multiple PERMNOs by keeping first match
and removing ambiguous duplicates.

# Arguments
- `df`: Input DataFrame with cusip and date columns
- `link_period`: Either "trace" (uses bondcrsp_link.sas7bdat) or other (uses BondEqLink.csv)

# Returns
DataFrame with permno column added

# Note
The linking table has errors where one CUSIP matches multiple PERMNOs.
This function deletes all duplicates in these cases.
See example: cusip == "007924AF0"
"""
function add_permno(df; link_period="trace")
    if link_period == "trace"
        links = DataFrame(readsas("data/wrds/bondcrsp_link.sas7bdat")) |> x->select(x, 1:3, 8:9) |> x-> rename(lowercase, x)
    else
        links = CSV.read("data/BondEqLink.csv", DataFrame) |> x-> rename(lowercase, x)
        select!(links, "full_cusip"=>identity=>"cusip", "permno", "link_startdt", "link_enddt")
        transform!(links, [:link_startdt, :link_enddt].=>ByRow(x->Date(string(x), DateFormat("yyyymmdd"))), renamecols=false)
    end
    links = innerjoin(df[:, [:date, :cusip]], links, on=:cusip)
    @rsubset!(links, :link_startdt <= :date <= :link_enddt)
    select!(links, Not([:link_startdt, :link_enddt]))
    links = dropduplicates(links, [:date, :cusip]; keep=:first)

    sum(nonunique(links, [:date, :cusip])) == 0 || error("Non-unique rows in linking table")
    df = leftjoin(df, links, on=[:cusip, :date])
    return df
end

# ============================================================================
# Statistical Functions
# ============================================================================

"""
    mean_vw(r, m)

Calculate value-weighted mean.

# Arguments
- `r`: Returns vector
- `m`: Market values/weights vector

# Returns
Value-weighted mean return
"""
mean_vw(r, m) = sum(skipmissing(r.*m), init=0.) ./ sum(skipmissing(m .* .!ismissing.(r)), init=0.)

"""
    sum_missing(x)

Sum that returns missing if all values are missing.
"""
function sum_missing(x)
    if all(ismissing.(x))
        return missing
    else
        return sum(skipmissing(x))
    end
end

# ============================================================================
# Cumulative Return Calculation
# ============================================================================

"""
    cumulative_return(df; ret_col=:ret_eom, period::Tuple=(12,48), level=:cusip, min_obs=nothing)

Compute cumulative return over specified previous period.

# Arguments
- `df`: Input DataFrame with returns
- `ret_col`: Name of return column (default: :ret_eom)
- `period`: Tuple (start_lag, end_lag) in months, e.g., (12,48) for 1-4 year past
- `level`: Grouping variable (default: :cusip)
- `min_obs`: Minimum required observations (default: nothing = require all)

# Returns
DataFrame with cumulative return column added

# Example
```julia
# Calculate cumulative return from 12 to 48 months ago
cumulative_return(df; period=(12,48), min_obs=30)
```
"""
function cumulative_return(df; ret_col=:ret_eom, period::Tuple=(12,48), level=:cusip, min_obs=nothing)
    typeof(min_obs) in [Nothing, Int] || error("min_obs has to be either nothing or an Int")
    if ret_col == :ret_eom
        name = "ret_$(period[2])_$(period[1])"  # Factor name, e.g. ret_48_12
    elseif ret_col == :ret_eq
        name = "ret_eq_$(period[2])_$(period[1])"
    end

    df = calendar_fill(df, date_col=:date, level=level)
    transform!(groupby(df, level), [ret_col => (r -> lag(r, i)) => "ret_lag"*string(i) for i in period[1]:period[2]])
    transform!(df, Cols(startswith("ret_lag")) .=> (x-> x .+ 1.), renamecols=false)

    # How to handle missing observations
    if min_obs == nothing
        dropmissing!(df, Cols(startswith("ret_lag")))
        transform!(df, AsTable(Cols(startswith("ret_lag"))) => ByRow(x->prod(x) - 1.) => name) # Cumulative return
    else  # Require min_obs to be non-missing
        select!(df, level, :date, AsTable(Cols(startswith("ret_lag"))) => ByRow(x->collect(skipmissing(x))) => name)
        subset!(df, name => ByRow(x->length(x) >= min_obs))
        transform!(df, name => ByRow(x->prod(x) - 1.) => name) # Cumulative return
    end
    select!(df, level, :date, name)
    return df
end
