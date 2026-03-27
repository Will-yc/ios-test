ios-release.yml

设置参数
/settings/secrets/actions


base64 -i distribution.p12 | tr -d '\n\r' > p12_base64.txt
base64 -i zyxctest.mobileprovision | tr -d '\n\r' > profile_base64.txt