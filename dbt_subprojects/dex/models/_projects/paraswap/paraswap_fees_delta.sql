{{ config(
	    schema='paraswap',
        alias = 'delta_fees',
        post_hook='{{ expose_spells(\'["ethereum","base"]\',
                                "project",
                                "paraswap",
                                \'["eptighte"]\') }}'
        )
}}


-- https://dune.com/queries/4335045

{% set 
    config = [
          ('ethereum', '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'),
          ('base', '0x4200000000000000000000000000000000000006')
    ]
%}


with
{% for row in config %}
    {% if not loop.first %}
    ,{% endif %}{{ paraswap_delta_v2_fees(row[0], row[1]) }}
{% endfor %}


{% for row in config %}
    {% if not loop.first %}
    union all
    (
    {% endif %}
        select '{{ row[0] }}' as blockchain, * from protocols_fees_balances_{{ row[0] }}
    {% if not loop.first %}
    )
    {% endif %}    
{% endfor %}
