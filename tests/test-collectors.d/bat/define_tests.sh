COLLECTOR_NAME="Batch"

COLLECTOR_TESTS=(
    "basic_submission;;.[0].response | fromjson | .id;^[0-9]+$"
)
