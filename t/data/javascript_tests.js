function test1() {
    str = 'a=1&b=2&c=3&c=4';
    var obj = toQueryParams(str);
    if(str != toQueryString(obj)) {
        diag("failed: " + str + " != " + toQueryString(obj));
        return 0;
    }
    return 1;
}