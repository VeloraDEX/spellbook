{% set blockchain = 'fantom' %}

{{ config(
        schema = 'metrics_' + blockchain
        , alias = 'transfers_daily_asset'
        , materialized = 'view'
        )
}}

SELECT *
FROM {{ source('tokens_fantom', 'net_transfers_daily_asset') }}
