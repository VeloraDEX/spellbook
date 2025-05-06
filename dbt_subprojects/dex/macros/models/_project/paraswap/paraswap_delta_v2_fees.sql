{% macro paraswap_delta_v2_fees(blockchain, weth) %}
-- to be called wrapped by "with"
    protocols_fees_balances_raw_{{blockchain}} as (
        select
            destToken as fee_token,
            prices.symbol as symbol,
            prices.decimals as decimals,
            prices.price as price,
            sum(protocolFee) as combined_protocol_fee_wei -- vs partnerFee            
        from
            paraswapdelta_{{ blockchain }}.ParaswapDeltav2_evt_OrderSettled as evt            
            left join prices.usd as prices on prices.blockchain = '{{ blockchain }}'
            and prices.contract_address =  (
                CASE 
                    WHEN destToken = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee THEN {{ weth }}
                    ELSE destToken 
                END
            )
            -- would be good to have real time pricing, but there's a availability lag, so resorting to 10h-old price 
            and prices.minute = DATE_TRUNC('hour', CURRENT_TIMESTAMP - interval '10' HOUR )
        group by
            1,
            2,
            3,
            4
    ), protocols_fees_balances_{{blockchain}} as (
        select
            fee_token, 
            symbol,
            decimals,
            price,
            combined_protocol_fee_wei/pow(10,decimals) as combined_protocol_fee_unit,
            price*combined_protocol_fee_wei/pow(10,decimals) as combined_usd_price
        from
            protocols_fees_balances_raw_{{blockchain}}

        {% if is_incremental() %}
            WHERE 
                {{ incremental_predicate('evt_block_time') }}
        {% endif %}              
    )
{% endmacro %}


