awk 'BEGIN { for(i=1; i<=15000000; i++) print "{\"id\": " i ", \"data\": \"load_test_payload\"}"}' > huge.jsonl
