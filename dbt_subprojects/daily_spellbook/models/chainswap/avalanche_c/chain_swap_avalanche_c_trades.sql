{{
    config(
        alias='trades',
        schema='chain_swap_avalanche_c',
        partition_by=['block_month'],
        materialized='incremental',
        file_format='delta',
        incremental_strategy='merge',
        incremental_predicates=[
            incremental_predicate('DBT_INTERNAL_DEST.block_time')
        ],
        unique_key=['blockchain', 'tx_hash', 'evt_index', 'fee_token_address'],
    )
}}

{% set project_start_date = '2024-03-28' %}
{% set blockchain = 'avalanche_c' %}
{% set deployer_1 = '0x9eC1ACAe39d07E1e8D8B3cEbe7022790D87D744A' %}
{% set deployer_2 = '0x415EEc63c95e944D544b3088bc682B759edB8548' %}
{% set deployer_3 = '0xc1cc1a300Dcfe5359eBe37f2007A77d1F91533ba' %}
{% set deployer_4 = '0xa24e8cE77D4A7Ce869DA3730e6560BfB66553F94' %}
{% set deployer_5 = '0xc8378819fbB95130c34D62f520167F745B13C305' %}
{% set deployer_6 = '0xde7Cb3d58D4004ff0De70995C0604089cc945EAF' %}
{% set wavax_contract_address = '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7' %}
{% set usdc_contract_address = '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E' %}
{% set fee_recipient_1 = '0x415EEc63c95e944D544b3088bc682B759edB8548' %}
{% set fee_recipient_2 = '0xe1ff5a4c489b11e094bfbb5d23c6d4597a3a79ad' %}

with
    bot_contracts as (
        select address
        from {{ source('avalanche_c', 'creation_traces') }}
        where
            (
                "from" = {{ deployer_1 }}
                or "from" = {{ deployer_2 }}
                or "from" = {{ deployer_3 }}
                or "from" = {{ deployer_4 }}
                or "from" = {{ deployer_5 }}
                or "from" = {{ deployer_6 }}
            )
            and block_time >= timestamp '{{project_start_date}}'
    ),
    bot_trades as (
        select
            trades.block_time,
            amount_usd,
            if(token_sold_address = {{ wavax_contract_address }}, 'Buy', 'Sell') as type,
            token_bought_amount,
            token_bought_symbol,
            token_bought_address,
            token_sold_amount,
            token_sold_symbol,
            token_sold_address,
            project,
            version,
            token_pair,
            project_contract_address,
            tx_from as user,
            tx_to as bot,
            trades.tx_hash,
            evt_index
        from {{ source('dex', 'trades') }} as trades
        join bot_contracts on trades.tx_to = bot_contracts.address
        where
            trades.blockchain = '{{blockchain}}'
            and (tx_from != {{ fee_recipient_1 }} and tx_from != {{ fee_recipient_2 }})
            {% if is_incremental() %}
            and {{ incremental_predicate('trades.block_time') }}
            {% else %}
            and trades.block_time >= timestamp '{{project_start_date}}'
            {% endif %}
    ),
    highest_event_index_for_each_trade as (
        select tx_hash, max(evt_index) as highest_event_index
        from bot_trades
        group by tx_hash
    ),
    fee_deposits as (
        select
            evt_tx_hash,
            value as fee_token_amount,
            contract_address as fee_token_address
        from {{ source('erc20_avalanche_c', 'evt_Transfer') }}
        where
            (to = {{ fee_recipient_1 }} or to = {{ fee_recipient_2 }})
            and value > 0
            and (
                contract_address = {{ wavax_contract_address }}
                or contract_address = {{ usdc_contract_address }}
            )
            {% if is_incremental() %}
            and {{ incremental_predicate('evt_block_time') }}
            {% else %}
            and evt_block_time >= timestamp '{{project_start_date}}'
            {% endif %}
        union all
        select
            tx_hash,
            value as fee_token_amount,
            {{ wavax_contract_address }} as fee_token_address
        from {{ source('avalanche_c', 'traces') }}
        where
            (to = {{ fee_recipient_1 }} or to = {{ fee_recipient_2 }})
            and value > 0
            {% if is_incremental() %}
            and {{ incremental_predicate('block_time') }}
            {% else %}
            and block_time >= timestamp '{{project_start_date}}'
            {% endif %}
    ),
    aggregated_fee_deposits as (
        select evt_tx_hash, sum(fee_token_amount) as fee_token_amount, fee_token_address 
        from fee_deposits 
        group by evt_tx_hash, fee_token_address
    )
select distinct
    block_time,
    date_trunc('day', block_time) as block_date,
    cast(date_trunc('month', block_time) as date) as block_month,
    '{{blockchain}}' as blockchain,
    -- Trade
    amount_usd,
    type,
    token_bought_amount,
    token_bought_symbol,
    cast(token_bought_address as varchar) as token_bought_address,
    token_sold_amount,
    token_sold_symbol,
    cast(token_sold_address as varchar) as token_sold_address,
    -- Fees
    fee_token_amount / power(10, decimals) * price as fee_usd,
    fee_token_amount / power(10, decimals) as fee_token_amount,
    symbol as fee_token_symbol,
    coalesce(fee_token_address, {{wavax_contract_address}}) as fee_token_address,
    -- Dex
    project,
    version,
    token_pair,
    cast(project_contract_address as varchar) as project_contract_address,
    -- User
    cast(user as varchar) as user,
    cast(bot_trades.tx_hash as varchar) as tx_hash,
    evt_index,
    if(evt_index = highest_event_index, true, false) as is_last_trade_in_transaction
from bot_trades
join
    highest_event_index_for_each_trade
    on bot_trades.tx_hash = highest_event_index_for_each_trade.tx_hash
left join aggregated_fee_deposits as fee_deposits on bot_trades.tx_hash = fee_deposits.evt_tx_hash
left join
    {{ source('prices', 'usd') }}
    on (
        blockchain = '{{blockchain}}'
        and contract_address = fee_token_address
        and minute = date_trunc('minute', block_time)
    )
order by block_time desc, evt_index desc
