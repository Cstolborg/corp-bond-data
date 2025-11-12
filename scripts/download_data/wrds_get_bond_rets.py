"""
Download and clean WRDS corporate bond returns
"""
import os
import numpy as np
import pandas as pd
import wrds

pd.set_option('display.max_columns', 15); pd.set_option('display.width', 320)

def load_ff(conn):
    """ Load Fama-French Monthly data """
    ff = conn.raw_sql(f"""
                    select e.date, e.mktrf, e.hml, e.smb, e.umd, e.rf
                    from ff.factors_monthly as e 
                                """, date_cols=['date'])
    ff['date'] += pd.offsets.MonthEnd(0)

    # Liquidity data from Pastor
    url = "https://finance.wharton.upenn.edu/~stambaug/liq_data_1962_2023.txt"
    liq = pd.read_csv(url, skiprows=11, header=None, sep='\s+')  # Liquidity data
    liq.columns = ["date", "agg_liq", "innov_liq", "liq"]
    liq.date = pd.to_datetime(liq.date, format="%Y%m") + pd.offsets.MonthEnd(0)
    liq.liq.replace(-99., np.nan, inplace=True)
    liq.dropna(inplace=True)
    liq = liq[["date", "liq"]]

    ff = ff.merge(liq, how="inner", on="date")
    ff.date = ff.date.astype(str)
    return ff

def load_ff_daily(conn):
    """ Load trading days from Kenneth French library """
    ff = conn.raw_sql(f"""
                    select e.date, e.mktrf, e.hml, e.smb, e.umd, e.rf
                    from ff.factors_daily as e 
                                """, date_cols=['date'])
    ff.date = ff.date.astype(str)
    return ff

def load_cusip_permno_gvkey(conn):
    crsp_link = conn.raw_sql(f"""
            select a.date, a.cusip, a.permno, a.permco,
            b.ncusip, b.exchcd, b.shrcd, b.ticker, b.comnam,
            c.gvkey			
            from crsp.msf as a 
            left join crsp.msenames as b
            on a.permno=b.permno and a.date>=namedt and a.date<=b.nameendt
            left join crsp.ccmxpf_lnkhist as c
            on a.permno=c.lpermno and (a.date>=c.linkdt or c.linkdt is null) and 
            (a.date<=c.linkenddt or c.linkenddt is null) and c.linktype in ('LC', 'LU', 'LS')
            """, date_cols=["date"])

    crsp_link['date'] = crsp_link['date'] + pd.offsets.MonthEnd(0)  # Ensure all data is eom
    crsp_link = crsp_link[crsp_link["exchcd"].isin([1,2,3]) & crsp_link["shrcd"].isin([10,11,12])]
    crsp_link.reset_index(drop=True, inplace=True)
    return crsp_link

if __name__ == '__main__':
    #PATH = "./data/wrds/"
    PATH = r'c:\\Users\\chris\\CBS Dropbox\\Christian Stolborg\\corp-bond-data\\data\\wrds\\'

    # Direct download from FRED (no API key or extra packages needed!)
    # ICE BofA 15+ Year US Corporate Index Total Return Index Value
    bofa_prices = 'BAMLCC8A015PYTRIV'
    url = f'https://fred.stlouisfed.org/graph/fredgraph.csv?id={bofa_prices}'
    fred = pd.read_csv(url, parse_dates=['observation_date'])
    fred.to_csv(PATH + "BAMLCC8A015PYTRIV.csv", index=False)

    # CBOE Volatility Index: VIX
    vix = 'VIXCLS'
    url = f'https://fred.stlouisfed.org/graph/fredgraph.csv?id={vix}'
    vix_df = pd.read_csv(url, parse_dates=['observation_date'])
    vix_df.to_csv(PATH + "VIXCLS.csv", index=False)

    # Load bond returns from WRDS
    conn = wrds.Connection(wrds_username='cstolborg')


    ff = load_ff(conn)
    ff.to_csv(PATH + "ff_monthly.csv", index=False)
    #ff.to_parquet(PATH + r"ff_monthly.pq", index=False)

    # TRADE dates from FF daily
    ff_daily = load_ff_daily(conn)
    ff_daily.to_csv(PATH + "ff_daily.csv", index=False)

    # TRACE Linking tables
    trace_links = conn.raw_sql(f"""
            SELECT *
            FROM wrdsapps.bondcrsp_link
                    """, date_cols=['date'])

    dt_cols = ["trace_startdt", "trace_enddt", "crsp_startdt", "crsp_enddt", "link_startdt", "link_enddt"]
    trace_links[dt_cols] = trace_links[dt_cols].apply(pd.to_datetime)
    trace_links.to_parquet(PATH + "link_table.pq")

    # PERMNO, GVKEY, CUSIP from CRSP
    crsp_link = load_cusip_permno_gvkey(conn)
    crsp_link.to_parquet(PATH + "cusip_permno_gvkey.pq")

