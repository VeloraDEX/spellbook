{{ config(
        schema='gmx_v2',
        alias = 'order_created',
        post_hook='{{ expose_spells(\'["arbitrum", "avalanche_c"]\',
                                    "project",
                                    "gmx",
                                    \'["ai_data_master","gmx-io"]\') }}'
        )
}}

{%- set chains = [
    'arbitrum',
    'avalanche_c',
] -%}

{%- for chain in chains -%}
SELECT
    blockchain,
    block_time,
    block_date,
    block_number,
    tx_hash,
    index,
    contract_address,
    tx_from,
    tx_to,   
    event_name,
    msg_sender,   
    account,
    receiver,
    callback_contract,
    ui_fee_receiver,
    market,
    initial_collateral_token,
    cancellation_receiver,
    swap_path,
    order_type,
    decrease_position_swap_type,    
    size_delta_usd,
    initial_collateral_delta_amount,
    trigger_price,
    trigger_price_raw,
    acceptable_price,
    acceptable_price_raw,
    execution_fee,
    callback_gas_limit,
    min_output_amount_raw, 
    updated_at_block,
    updated_at_time,
    valid_from_time,
    is_long,
    should_unwrap_native_token,
    auto_cancel,
    key,
    data_list
FROM {{ ref('gmx_v2_' ~ chain ~ '_order_created') }}
{% if not loop.last %}
UNION ALL
{% endif %}
{%- endfor -%}