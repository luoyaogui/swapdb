#verify redis/ssdb's dump/restore API
start_server {tags {"redis-ssdb"}} {
    set ssdb [redis $::host $::ssdbport]

#string type
    foreach valtype {string-encoded integer-encoded mix-encoded} {
        if {$valtype == "string-encoded"} {
            set bar bar
        } elseif {$valtype == "integer-encoded"} {
            set bar 123
        } elseif {$valtype == "mix-encoded"} {
            set bar bar123
        }

        test "string $valtype Be Hot ssdb dump/redis restore" {
            r del foo
            $ssdb set foo $bar
            set ssdbEncoded [$ssdb dump foo]
            $ssdb del foo
            r restore foo 0 $ssdbEncoded
            assert_equal $bar [ r get foo ]
        }

        test "string $valtype Be Cold redis dump/ssdb restore" {
            r del foo
            r set foo $bar
            set redisEncoded [r dump foo]
            r del foo
            $ssdb restore foo 0 $redisEncoded
            assert_equal $bar [ $ssdb get foo ]
        }
    }

#hash type
    foreach encoding { ziplist hashtable} {
        if {$encoding == "ziplist"} {
            set num 8
        } elseif {$encoding == "hashtable"} {
            set num 1024
        }

        test "hash ($encoding) creation" {
            r del myhash
            array set myhash {}
            unset myhash
            for {set i 0} {$i < $num} {incr i} {
                set key __avoid_collisions__[randstring 0 8 alpha]
                set val __avoid_collisions__[randstring 0 8 alpha]
                if {[info exists myhash($key)]} {
                    incr i -1
                    continue
                }
                r hset myhash $key $val
                set myhash($key) $val
            }
            assert {[r object encoding myhash] eq $encoding}
        }

        test "hash ($encoding) Be Cold redis dump/ssdb restore" {
            set redisEncoded [r dump myhash]

            r del myhash
            $ssdb restore myhash 0 $redisEncoded

            set err {}
            foreach k [array names myhash *] {
                if {$myhash($k) ne [$ssdb hget myhash $k]} {
                    set err "$myhash($k) != [$ssdb hget myhash $k]"
                    break
                }
            }
            set _ $err
        } {}

        test "hash ($encoding) Be Hot ssdb dump/redis restore" {
            set ssdbEncoded [$ssdb dump myhash]

            $ssdb del myhash

            r restore myhash 0 $ssdbEncoded
            set err {}
            foreach k [array names myhash *] {
                if {$myhash($k) ne [r hget myhash $k]} {
                    set err "$myhash($k) != [r hget myhash $k]"
                    break
                }
            }
            r del myhash
            set _ $err
        } {}

        test {RESTORE can detect a syntax error for unrecongized options} {
            catch {$ssdb restore myhash 0 $redisEncoded invalid-option} e
            set e
        } {*ERR*}
    }
# set type
    foreach valtype {string-encoded mix-encoded integer-encoded overflownumbers} \
        encoding { hashtable hashtable intset hashtable } {
        if {$valtype == "string-encoded"} {
            set list [list a b c d e f g]
        } elseif {$valtype == "mix-encoded"} {
            set list [list 1 2 3 4 5 6 7 a b c d e f g]
        } elseif {$valtype == "integer-encoded"} {
            set list [list 1 2 3 4 5 6 7]
        } elseif {$valtype == "overflownumbers"} {
            set list {}
            for {set i 0} {$i <=  512} {incr i} { 
                lappend list $i
            }
        }

        test "set ($encoding) $valtype creation" {
            r del myset
            foreach i $list {
                r sadd myset $i
            }
            assert {[r object encoding myset] eq $encoding}
        }

        test "set ($encoding) $valtype Be Cold redis dump/ssdb restore" {
            set redisEncoded [r dump myset]
            r del myset
            $ssdb restore myset 0 $redisEncoded

            assert_equal [lsort $list] [lsort [$ssdb smembers myset]]
        }

        test "set ($encoding) $valtype Be Hot ssdb dump/redis restore" {
            set ssdbEncoded [$ssdb dump myset]
            $ssdb del myset
            r restore myset 0 $ssdbEncoded

            assert_equal [lsort $list] [lsort [r smembers myset]]
            r del myset
        }

        test {RESTORE (SSDB) can set an arbitrary expire to the materialized key} {
            $ssdb del foottl
            $ssdb restore foottl 5000 $redisEncoded
            set ttl [$ssdb pttl foottl]
            assert {$ttl >= 3000 && $ttl <= 5000}
        }
        r del foottl
    }

#zset type
    foreach encoding {ziplist skiplist} {
        if {$encoding == "ziplist"} {
            r config set zset-max-ziplist-entries 128
            r config set zset-max-ziplist-value 64
        } elseif {$encoding == "skiplist"} {
            r config set zset-max-ziplist-entries 1
            r config set zset-max-ziplist-value 1
        }

        test "zset ($encoding) creation" {
            r del myzset
            set list {}
            foreach i {1 2 3 4} j {a b c d} {
                r zadd myzset $i $j
                lappend list $j $i
            }
            assert {[r object encoding myzset] eq $encoding}
        }

        test "zset ($encoding) Be Cold redis dump/ssdb restore" {
            set redisEncoded [r dump myzset]
            r del myzset
            $ssdb restore myzset 0 $redisEncoded

            assert_equal $list [$ssdb zrange myzset 0 -1 withscores]
        }

        test "zset ($encoding) Be Hot ssdb dump/redis restore" {
            set ssdbEncoded [$ssdb dump myzset]
            $ssdb del myzset
            r restore myzset 0 $ssdbEncoded

            assert_equal $list [r zrange myzset 0 -1 withscores]
            r del myzset
        }

        test {RESTORE (SSDB) can set an expire that overflows a 32 bit integer} {
            $ssdb del foottl
            $ssdb restore foottl 2569591501 $redisEncoded
            set ttl [$ssdb pttl foottl]
            assert {$ttl >= 2569591501-3000 && $ttl <= 2569591501}
        }
        r del foottl
    }

#list type
    foreach valtype {string-encoded integer-encoded mix-encoded} {
        if {$valtype == "string-encoded"} {
            set list [list a b c d e f g]
        } elseif {$valtype == "integer-encoded"} {
            set list [list 1 2 3 4 5 6 7]
        } elseif {$valtype == "mix-encoded"} {
            set list [list 1 2 3 4 5 6 7 a b c d e f g]
        }
        
        test "list (quicklist) $valtype creation" {
            r del mylist
            foreach i $list {
                r lpush mylist $i
            }
            assert {[r object encoding mylist] eq {quicklist}}
        }

        test "list (quicklist) $valtype Be Cold redis dump/ssdb restore" {
            set redisEncoded [r dump mylist]
            r del mylist
            $ssdb restore mylist 0 $redisEncoded

            assert_equal [lsort $list] [lsort [$ssdb lrange mylist 0 -1]]
        }

        test "list (quicklist) $valtype Be Hot ssdb dump/redis restore" {
            set ssdbEncoded [$ssdb dump mylist]
            $ssdb del mylist
            r restore mylist 0 $ssdbEncoded

            assert_equal [lsort $list] [lsort [r lrange mylist 0 -1]]
            r del mylist
        }

        test {RESTORE (SSDB) returns an error of the key already exists} {
            $ssdb del foobusy
            $ssdb set foobusy barbusy
            set e {}
            catch { $ssdb restore foobusy 0 $redisEncoded } e
            list [set e] [ $ssdb get foobusy ]
        } {*ERR* barbusy}

        test {RESTORE (SSDB) can overwrite an existing key with REPLACE} {
            $ssdb restore foobusy 0 $redisEncoded replace
            assert_equal [lsort $list] [lsort [$ssdb lrange foobusy 0 -1]]
        }
        r del foobusy
    }

    # add to verify dump/restore directly for fuzzing test fail issue
    foreach size {10 512} {
        test "Hash fuzzing #1 - $size fields" {
            for {set times 0} {$times < 10} {incr times} {
                catch {unset hash}
                array set hash {}
                r del hash

                # Create
                for {set j 0} {$j < $size} {incr j} {
                    set field [randomValue]
                    set value [randomValue]
                    r hset hash $field $value
                    set hash($field) $value
                }

                set redisEncoded [r dump hash]
                r del hash
                $ssdb restore hash 0 $redisEncoded replace

                foreach {k v} [array get hash] {
                    # puts "$k $v"
                    assert_equal $v [$ssdb hget hash $k]
                }
                assert_equal [array size hash] [$ssdb hlen hash]

                set ssdbEncoded [$ssdb dump hash]
                r restore hash 0 $ssdbEncoded replace
                $ssdb del hash

                # Verify
                foreach {k v} [array get hash] {
                    assert_equal $v [r hget hash $k]
                }
                assert_equal [array size hash] [r hlen hash]
            }
            r del hash
        }
    }
    $ssdb flushdb
}
