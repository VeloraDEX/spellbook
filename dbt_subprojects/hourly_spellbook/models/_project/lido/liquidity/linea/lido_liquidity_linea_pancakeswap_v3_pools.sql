{{ config(
    schema='lido_liquidity_linea',
    alias = 'pancakeswap_v3_pools',
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['pool', 'time'],
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.time')],
    post_hook='{{ expose_spells(blockchains = \'["linea"]\',
                                spell_type = "project",
                                spell_name = "lido_liquidity",
                                contributors = \'["pipistrella"]\') }}'
    )
}}

{% set project_start_date = '2023-12-01' %}

with

pools as (
select pool as address, 'linea' as blockchain, 'pancakeswap' as project, max(cast(fee as double))/10000 as fee
from {{ source('pancakeswap_v3_linea','pancakev3factory_evt_poolcreated')}}
where token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F or token1 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F
group by 1,2,3
)

, tokens as (
select distinct token as address
from (
select token1 as token
from {{ source('pancakeswap_v3_linea','pancakev3factory_evt_poolcreated')}}
where token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F
union
select token0
from {{ source('pancakeswap_v3_linea','pancakev3factory_evt_poolcreated')}}
where token1 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F
union
select 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F
) t
)

, tokens_prices_daily AS (
    SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        contract_address as token,
        decimals,
        symbol,
        avg(price) AS price
    FROM {{ source('prices', 'usd') }} p
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', p.minute) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('p.minute') }}
    {% endif %}
    and date_trunc('day', minute) < current_date
    and blockchain = 'linea'
    and contract_address in (select address from tokens)
    group by 1,2,3,4
    union all
    SELECT distinct
        DATE_TRUNC('day', minute),
        contract_address as token,
        decimals,
        symbol,
        last_value(price) over (partition by DATE_TRUNC('day', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{ source('prices', 'usd') }}
    WHERE date_trunc('day', minute) = current_date
    and blockchain = 'linea'
    and contract_address in (select address from tokens)
)

, tokens_prices_hourly AS (
    select  time,
            lead(time,1, DATE_TRUNC('hour', now() + interval '1' hour)) over (partition by token order by time) as next_time,
            token, price, decimals, symbol
    from (
    SELECT distinct
        DATE_TRUNC('hour', minute) time,
        contract_address as token,
        decimals,
        symbol,
        last_value(price) over (partition by DATE_TRUNC('hour', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{ source('prices', 'usd') }} p
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', p.minute) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('p.minute') }}
    {% endif %}
    and blockchain = 'linea'
    and contract_address in (select address from tokens)
) p
)


, swap_events as (
    select
        date_trunc('day', sw.evt_block_time) as time,
        sw.contract_address as pool,
        cr.token0, cr.token1,
        sum(cast(amount0 as DOUBLE)) as amount0,
        sum(cast(amount1 as DOUBLE)) as amount1

    from {{ source('pancakeswap_v3_linea', 'pancakev3pool_evt_swap') }} sw
    left join {{ source('pancakeswap_v3_linea', 'pancakev3factory_evt_poolcreated') }} cr on sw.contract_address = cr.pool
    join pools on sw.contract_address = pools.address
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', sw.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('sw.evt_block_time') }}
    {% endif %}
    group by 1,2,3,4
)

, mint_events as (
    select
        date_trunc('day', mt.evt_block_time) as time,
        mt.contract_address as pool,
        cr.token0, cr.token1,
        sum(cast(amount0 as DOUBLE)) as amount0,
        sum(cast(amount1 as DOUBLE)) as amount1
    from {{ source('pancakeswap_v3_linea', 'pancakev3pool_evt_mint') }} mt
    left join {{ source('pancakeswap_v3_linea', 'pancakev3factory_evt_poolcreated') }} cr on mt.contract_address = cr.pool
    join pools on mt.contract_address = pools.address
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', mt.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('mt.evt_block_time') }}
    {% endif %}
    
    group by 1,2,3,4

)

, burn_events as (
    select
        date_trunc('day', bn.evt_block_time) as time,
        bn.contract_address as pool,
        cr.token0, cr.token1,
        (-1)*sum(cast(amount0 as DOUBLE)) as amount0,
        (-1)*sum(cast(amount1 as DOUBLE)) as amount1
    from {{ source('pancakeswap_v3_linea', 'pancakev3pool_evt_burn') }} bn
    left join {{ source('pancakeswap_v3_linea', 'pancakev3factory_evt_poolcreated') }} cr on bn.contract_address = cr.pool
    join pools on bn.contract_address = pools.address
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', bn.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('bn.evt_block_time') }}
    {% endif %}
    
    group by 1,2,3,4

)

  , collect_events AS (
    SELECT
       date_trunc('day', c.evt_block_time) as time,
      c.contract_address AS pool,
      cr.token0,
      cr.token1,
      (-1) * CAST(amount0 AS DOUBLE) AS amount0,
      (-1) * CAST(amount1 AS DOUBLE) AS amount1,
      c.evt_tx_hash
    FROM
      {{source('pancakeswap_v3_linea','pancakev3pool_evt_collect')}} AS c
      LEFT JOIN {{source('pancakeswap_v3_linea','pancakev3factory_evt_poolcreated')}} AS cr ON c.contract_address = cr.pool
      join pools on c.contract_address = pools.address
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', c.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('c.evt_block_time') }}
    {% endif %}
    
  )


, daily_delta_balance as (
    select time, pool, token0, token1, sum(coalesce(amount0, 0)) as amount0, sum(coalesce(amount1, 0)) as amount1
    from (
    select time, pool, token0, token1, amount0, amount1
    from swap_events
    union all
    select time, pool, token0, token1, amount0, amount1
    from mint_events
    union all
    select time, pool, token0, token1, amount0, amount1
    from collect_events
    ) balance
    group by 1,2,3,4
)

, pool_liquidity as (
    select  time,
            pool,
            token0,
            token1,
            sum(amount0) as amount0,
            sum(amount1) as amount1
    from daily_delta_balance
    group by 1,2,3,4
)


, swap_events_hourly as (
    select hour, pool, token0, token1, sum(amount0) as amount0, sum(amount1) as amount1 from (
    select
        date_trunc('hour', sw.evt_block_time) as hour,
        sw.contract_address as pool,
        cr.token0, cr.token1,
        coalesce(sum(cast(abs(amount0) as DOUBLE)),0) as amount0,
        coalesce(sum(cast(abs(amount1) as DOUBLE)),0) as amount1

    from {{source('pancakeswap_v3_linea','pancakev3pool_evt_swap')}} sw
    left join {{source('pancakeswap_v3_linea','pancakev3factory_evt_poolcreated')}} cr on sw.contract_address = cr.pool
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', sw.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('sw.evt_block_time') }}
    {% endif %}
    and sw.contract_address in (select address from pools)
    group by 1,2,3,4

      ) a group by 1,2,3,4
)

, trading_volume_hourly as (
    select hour as time, pool, token0, amount0, p.price, coalesce(p.price*amount0/power(10, p.decimals),0) as volume
    from swap_events_hourly s
    left join tokens t on s.token0 = t.address
    left join tokens_prices_hourly p on  s.hour >= p.time and s.hour < p.next_time  and s.token0 = p.token

)

, trading_volume as (
select  distinct date_trunc('day', time) as time, pool, sum(volume) as volume
from trading_volume_hourly
group by 1,2
)

, all_metrics as (
select l.pool, pools.blockchain, pools.project, pools.fee, cast(l.time as date) as time,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then token0 else token1 end main_token,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then p0.symbol else p1.symbol end main_token_symbol,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then token1 else token0 end paired_token,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then p1.symbol else p0.symbol end paired_token_symbol,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then amount0/power(10, p0.decimals)  else amount1/power(10, p1.decimals)  end main_token_reserve,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then amount1/power(10, p1.decimals)  else amount0/power(10, p0.decimals)  end paired_token_reserve,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then p0.price else p1.price end as main_token_usd_price,
    case when token0 = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F then p1.price else p0.price end as paired_token_usd_price,
    volume as trading_volume
from pool_liquidity l
left join pools on l.pool = pools.address
left join tokens t0 on l.token0 = t0.address
left join tokens t1 on l.token1 = t1.address
left join tokens_prices_daily p0 on l.time = p0.time and l.token0 = p0.token
left join tokens_prices_daily p1 on l.time = p1.time and l.token1 = p1.token
left join trading_volume tv on l.time = tv.time and l.pool = tv.pool
)



select blockchain||' '||project||' '||COALESCE(paired_token_symbol, 'unknown')||':'||main_token_symbol||' '||format('%,.3f',round(coalesce(fee,0),4)) as pool_name,*
from all_metrics

