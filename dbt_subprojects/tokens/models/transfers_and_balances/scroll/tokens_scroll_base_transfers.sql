{{config(
    schema = 'tokens_scroll',
    alias = 'base_transfers',
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')],
    unique_key = ['block_date','unique_key'],
)
}}

{{transfers_base(
    blockchain='scroll',
    traces = source('scroll','traces'),
    transactions = source('scroll','transactions'),
    erc20_transfers = source('erc20_scroll','evt_Transfer'),
    native_contract_address = null
)
}}
