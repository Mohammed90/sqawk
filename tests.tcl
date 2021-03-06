#!/usr/bin/env tclsh
# Sqawk, an SQL Awk.
# Copyright (C) 2015, 2016, 2017 dbohdan
# License: MIT

package require fileutil
package require struct
package require tcltest

namespace eval ::sqawk::tests {
    variable path [file dirname [file dirname [file normalize $argv0/___]]]
    variable cleanupVars {}

    if {[llength $argv] > 0} {
        tcltest::configure -match $argv
    }

    proc make-temp-file content {
        return [tcltest::makeFile $content [::fileutil::tempfile]]
    }

    proc init args {
        cd $::sqawk::tests::path
        set ::sqawk::tests::cleanupVars {}
        foreach {varName content} $args {
            upvar 1 $varName f
            set f [make-temp-file $content]
            lappend ::sqawk::tests::cleanupVars $varName
        }
    }

    proc uninit {} {
        foreach varName $::sqawk::tests::cleanupVars {
            upvar 1 $varName f
            tcltest::removeFile $f
            unset f
        }
    }

    # Run Sqawk with {*}$args.
    proc sqawk-tcl args {
        exec [info nameofexecutable] sqawk.tcl {*}$args
    }

    # Return 1 if $version in the format of X.Y.Z.W is newer than $reference and
    # 0 otherwise.
    proc newer-or-equal {version reference} {
        foreach a [split $version .] b [split $reference .] {
            if {$a > $b} {
                return 1
            } elseif {$a < $b} {
                return 0
            }
        }
        return 1
    }

    # Set the constraints.
    set sqliteVersion [sqawk-tcl {select sqlite_version()} << {}]
    tcltest::testConstraint printfInSqlite3 \
            [newer-or-equal $sqliteVersion 3.8.3]
    tcltest::testConstraint jimsh [expr {
        ![catch { exec jimsh << {} }]
    }]
    tcltest::testConstraint utf8 [expr {
        [encoding system] eq {utf-8}
    }]

    tcltest::test error-handling-1.1 {Handle broken pipe, read from stdin} \
            -setup {
        init filename "line 1\nline 2\nline 3" \
             script {
                 fconfigure stdin -buffering line
                 puts [gets stdin]
                 exit 0
             }
    } -body {
        sqawk-tcl {select a0 from a} < $filename \
                | [info nameofexecutable] $script
    } -cleanup {
        uninit
    } -result {line 1}

    tcltest::test error-handling-2.1 {Fail on bad query} -setup {
        init
    } -body {
        sqawk-tcl -1 asdf sqawk-tcl
    } -cleanup {
        uninit
    } -returnCodes 1 -match regexp -result {\s+}

    tcltest::test error-handling-2.2 {Fail on missing file} -setup {
        init
    } -body {
        sqawk-tcl -1 {select a0 from a} missing-file
    } -cleanup {
        uninit
    } -returnCodes 1 -match glob -result {*can't find file "missing-file"*}

    proc difference {filename1 filename2} {
        set lines1 [split [::fileutil::cat $filename1] \n]
        set lines2 [split [::fileutil::cat $filename2] \n]
        set lcs [::struct::list longestCommonSubsequence $lines1 $lines2]

        return [::struct::list lcsInvert $lcs [llength $lines1] \
                [llength $lines2]]
    }

    tcltest::test join-1.1 {JOIN on two files from examples/hp/} -setup {
        init filename {}
    } -body {
        sqawk-tcl {
            select a1, b1, a2 from a inner join b on a2 = b2
            where b1 < 10000 order by b1
        } examples/hp/MD5SUMS examples/hp/du-bytes > $filename
        difference examples/hp/results.correct $filename
    } -cleanup {
        uninit
    } -result {}

    tcltest::test join-2.1 {JOIN on files from examples/three-files/,\
            FS setting} -setup {
        init filename {}
    } -body {
        set dir examples/three-files/
        sqawk-tcl -FS , {
            select a1, a2, b2, c2 from a inner join b on a1 = b1
            inner join c on a1 = c1
        } $dir/1 FS=_ FS=, $dir/2 $dir/3 > $filename
        unset dir
        difference examples/three-files/results.correct $filename
    } -cleanup {
        uninit
    } -result {}

    tcltest::test table-1.1 {Custom table names} -setup {
        init filename1 "foo 1\nfoo 2\nfoo 3" \
             filename2 "bar 4\nbar 5\nbar 6"
    } -body {
        sqawk-tcl {
            select foo2 from foo; select b2 from b
        } table=foo $filename1 $filename2
    } -cleanup {
        uninit
    } -result "1\n2\n3\n4\n5\n6"

    tcltest::test table-1.2 {Custom table names and prefixes} -setup {
        init filename1 "foo 1\nfoo 2\nfoo 3" \
             filename2 "bar 4\nbar 5\nbar 6"
    } -body {
        sqawk-tcl {
            select foo.x2 from foo; select baz2 from bar
        } table=foo prefix=x $filename1 table=bar prefix=baz $filename2
    } -cleanup {
        uninit
    } -result "1\n2\n3\n4\n5\n6"

    tcltest::test header-1.1 {Header row} -setup {
        set content {}
        append content "name\tposition\toffice\tphone\n"
        append content "Smith\tCEO\t10\t555-1234\n"
        append content "James\tHead of marketing\t11\t555-1235\n"
        append content "McDonald\tDeveloper\t12\t555-1236\tGood at tables\n"
        init filename $content
        unset content
    } -body {
        sqawk-tcl {
            select name, office from staff
            where position = "CEO"
                    or staff.phone = "555-1234"
                    or staff.a5 = "Good at tables"
        } FS=\t table=staff prefix=a header=1 $filename
    } -cleanup {
        uninit
    } -result "Smith 10\nMcDonald 12"

    tcltest::test header-1.2 {Header row with spaces} -setup {
        set content {}
        append content "id,a column with a long name,\"even worse - quotes!\"\n"
        append content "1,foo,!\n"
        append content "2,bar,%\n"
        append content "3,baz,$\n"
        init filename $content
        unset content
    } -body {
        sqawk-tcl {
            select "a column with a long name" from a;
            select `"even worse - quotes!"` from a
        } FS=, header=1 $filename
    } -cleanup {
        uninit
    } -result "foo\nbar\nbaz\n!\n%\n$"

    tcltest::test header-3.1 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select hello, a2 from a} columns=hello $header3File
    } -cleanup {
        uninit
    } -result "1 a\n2 b\n3 c"

    tcltest::test header-3.2 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select a1, a2 from a} columns=,,world $header3File
    } -cleanup {
        uninit
    } -result "1 a\n2 b\n3 c"

    tcltest::test header-3.3 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select "hello world" from a} {columns=hello world} \
                $header3File
    } -cleanup {
        uninit
    } -result 1\n2\n3

    tcltest::test header-3.4 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select world from a} columns=hello,world $header3File
    } -cleanup {
        uninit
    } -result a\nb\nc

    tcltest::test header-3.5 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select world from a} columns=hello,world,of,tables \
                $header3File
    } -cleanup {
        uninit
    } -result a\nb\nc \

    tcltest::test header-3.6 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select hello from a} header=1 columns=hello,world \
                $header3File
    } -cleanup {
        uninit
    } -result 2\n3

    tcltest::test header-3.7 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select hello, a from a} header=1 columns=hello \
                $header3File
    } -cleanup {
        uninit
    } -result "2 b\n3 c"

    tcltest::test header-3.8 {"columns" per-file option} -setup {
        init header3File "001 a\n002 b\n003 c\n"
    } -body {
        sqawk-tcl {select a from a} header=1 columns= $header3File
    } -cleanup {
        uninit
    } -result b\nc

    tcltest::test field-mapping-1.1 {::sqawk::parsers::awk::valid-range?} \
            -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::valid-range? 0 1]
        lappend result [::sqawk::parsers::awk::valid-range? -5 1]
        lappend result [::sqawk::parsers::awk::valid-range? 1 0]
        lappend result [::sqawk::parsers::awk::valid-range? 5 end]
        lappend result [::sqawk::parsers::awk::valid-range? end 5]
        lappend result [::sqawk::parsers::awk::valid-range? start end]
        lappend result [::sqawk::parsers::awk::valid-range? start 5]
        lappend result [::sqawk::parsers::awk::valid-range? blah blah]
        lappend result [::sqawk::parsers::awk::valid-range? 999 9999]
    } -cleanup {
        unset result
        uninit
    } -result {1 0 0 1 0 0 0 0 1}

    tcltest::test field-mapping-1.2 {::sqawk::parsers::awk::in-range?} \
            -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::in-range? 5 {0 1}]
        lappend result [::sqawk::parsers::awk::in-range? 5 {0 5}]
        lappend result [::sqawk::parsers::awk::in-range? 5 {0 99}]
        lappend result [::sqawk::parsers::awk::in-range? 0 {0 0}]
        lappend result [::sqawk::parsers::awk::in-range? 0 {1 1}]
        lappend result [::sqawk::parsers::awk::in-range? 1 {0 0}]
        lappend result [::sqawk::parsers::awk::in-range? 3 {5 end}]
        lappend result [::sqawk::parsers::awk::in-range? 5 {5 end}]
        lappend result [::sqawk::parsers::awk::in-range? 7 {5 end}]
    } -cleanup {
        unset result
        uninit
    } -result {0 3 2 1 0 0 0 1 2}

    tcltest::test field-mapping-1.3 {::sqawk::parsers::awk::parseFieldMap} \
            -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::parseFieldMap auto]
        lappend result [::sqawk::parsers::awk::parseFieldMap 1,2]
        lappend result [::sqawk::parsers::awk::parseFieldMap 1,1-2,3,5-end]
    } -cleanup {
        unset result
        uninit
    } -result [list \
            auto \
            {{1 1} {2 2}} \
            {{1 1} {1 2} {3 3} {5 end}} \
    ]

    tcltest::test field-mapping-2.1 {::sqawk::parsers::awk::map} -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{1 99}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{1 end}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{1 1}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{1 2}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{4 5}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{1 1} {2 2} {3 3}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{1 1} {2 2} {3 end}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {{1 1} {2 3} {3 3}}]
    } -cleanup {
        unset result
        uninit
    } -result [list \
            startABfooABbar \
            startABfooABbar \
            start \
            startABfoo \
            {{}} \
            {start foo bar} \
            {start foo bar} \
            {start fooABbar bar} \
    ]

    tcltest::test field-mapping-2.2 {::sqawk::parsers::awk::map} -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 99}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 end}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 1}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 2}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{4 5}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 1} {2 2} {3 3}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 1} {2 2} {3 end}}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 1} {2 3} {3 3}}]
    } -cleanup {
        unset result
        uninit
    } -result [list \
            startABfooABbarAB \
            startABfooABbarAB \
            start \
            startABfoo \
            {{}} \
            {start foo bar} \
            {start foo barAB} \
            {start fooABbar bar} \
    ]

    tcltest::test field-mapping-2.3 {::sqawk::parsers::awk::map auto} -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar {}} {auto}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {auto}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 1} auto}]
        lappend result [::sqawk::parsers::awk::map \
                {start AB foo AB bar AB} {{1 1} {2 2} auto}]
    } -cleanup {
        unset result
        uninit
    } -result [list \
            {start foo bar} \
            {start foo bar} \
            {start foo bar} \
            {start foo bar} \
    ]

    tcltest::test field-mapping-2.3 {::sqawk::parsers::awk::map} -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::map \
                {foo { } 1 {   } foo { } 2 {   } foo { } 3 {}} \
                {{1 2} {3 4} {5 6}}]
        lappend result [::sqawk::parsers::awk::map \
                {bar {    } 4 { } bar {    } 5 { } bar {    } 6 {}} \
                {{1 2} {3 4} {5 6}}]
    } -cleanup {
        unset result
        uninit
    } -result {{{foo 1} {foo 2} {foo 3}} {{bar    4} {bar    5} {bar    6}}}

    tcltest::test field-mapping-2.4 {::sqawk::parsers::awk::map} -setup {
        init
    } -body {
        source -encoding utf-8 sqawk.tcl
        set result {}
        lappend result [::sqawk::parsers::awk::map \
                {foo { } 1 {   } foo { } 2 {   } foo { } 3 {}} \
                {{2 2} {4 4} {6 6}}]
        lappend result [::sqawk::parsers::awk::map \
                {bar {    } 4 { } bar {    } 5 { } bar {    } 6 {}} \
                {{2 2} {4 4} {6 6}}]
    } -cleanup {
        unset result
        uninit
    } -result {{1 2 3} {4 5 6}}

    variable merge2File [make-temp-file \
            "foo 1   foo 2   foo 3\nbar    4 bar    5 bar    6\n"]

    tcltest::test field-mapping-3.1 {merge fields} -setup {
        init merge2File "foo 1   foo 2   foo 3\nbar    4 bar    5 bar    6\n"
    } -body {
        sqawk-tcl -OFS - {
            select a1, a2, a3 from a
        } {fields=1-2,3-4,5-6} $merge2File
    } -cleanup {
        uninit
    } -result "foo 1-foo 2-foo 3\nbar    4-bar    5-bar    6"

    tcltest::test field-mapping-3.2 {skip fields} -setup {
        init merge2File "foo 1   foo 2   foo 3\nbar    4 bar    5 bar    6\n"
    } -body {
        sqawk-tcl -OFS - {
            select a1, a2 from a
        } {fields=3,6} $merge2File
    } -cleanup {
        uninit
    } -result "foo-3\nbar-6"

    tcltest::test field-mapping-3.3 {skip and merge fields} -setup {
        init merge2File "foo 1   foo 2   foo 3\nbar    4 bar    5 bar    6\n"
    } -body {
        sqawk-tcl -OFS - {
            select a1, a2 from a
        } {fields=1-2,5-6} $merge2File
    } -cleanup {
        uninit
    } -result "foo 1-foo 3\nbar    4-bar    6"

    tcltest::test format-1.1 {CSV input} -constraints {
        utf8
    } -setup {
        init filename "1,2,\"Hello, World!\"\nΑλαμπουρνέζικα,3,4\n5,6,7"
    } -body {
        sqawk-tcl -OFS - {
            select a1, a2, a3 from a
        } format=csv $filename
    } -cleanup {
        uninit
    } -result "1-2-Hello, World!\nΑλαμπουρνέζικα-3-4\n5-6-7"

    tcltest::test format-1.2 {CSV input} -constraints {
        utf8
    } -setup {
        init filename "1;2;\"Hello, World!\"\nΑλαμπουρνέζικα;3;4\n5;6;7"
    } -body {
        sqawk-tcl -OFS - {
            select a1, a2, a3 from a
        } format=csvalt {csvsep=;} $filename
    } -cleanup {
        uninit
    } -result "1-2-Hello, World!\nΑλαμπουρνέζικα-3-4\n5-6-7"

    tcltest::test format-2.1 {Tcl data input} -setup {
        init
    } -body {
        sqawk-tcl -OFS \\| {
            select * from a
        } format=tcl << {{1 2 3   4   5       } {6 7 8 9 10}}
    } -cleanup {
        uninit
    } -result [format %s\n%s \
            {1|5|1 2 3   4   5       |1|2|3|4|5|||||} \
            {2|5|6 7 8 9 10|6|7|8|9|10|||||}]

    tcltest::test format-2.2 {Tcl data input} -setup {
        init filename {{foo 1 bar 2} {foo 3 bar 4 baz 5}}
    } -body {
        sqawk-tcl -output json {
            select foo, bar, baz from a
        } format=tcl dicts=1 header=1 $filename
    } -cleanup {
        uninit
    } -result {[{"foo":"1","bar":"2","baz":""},{"foo":"3","bar":"4","baz":"5"}]}

    tcltest::test format-2.3 {Tcl data input} -setup {
        init
    } -body {
        sqawk-tcl -OFS \\| -NF 3 {
            select * from a
        } format=tcl dicts=1 << {{ b  2} {a   1  }}
    } -cleanup {
        uninit
    } -result "1|2|b a|b|a|\n2|2| b  2|2||\n3|2|a   1  ||1|"

    tcltest::test output-1.1 {Default output format} -setup {
        init filename "line 1\nline 2\nline 3"
    } -body {
        sqawk-tcl -output awk {select a0 from a} $filename
    } -cleanup {
        uninit
    } -result "line 1\nline 2\nline 3"

    variable output2File [make-temp-file "a,b\n1,2"]

    tcltest::test output-2.1 {CSV output} -setup {
        init output2File a,b\n1,2
    } -body {
        sqawk-tcl -output awk {select a1 from a} $output2File
    } -cleanup {
        uninit
    } -result a,b\n1,2

    tcltest::test output-2.2 {CSV output} -setup {
        init output2File a,b\n1,2
    } -body {
        sqawk-tcl -output csv {select a1 from a} $output2File
    } -cleanup {
        uninit
    } -result \"a,b\"\n\"1,2\"

    tcltest::test output-3.1 {Tcl output} -setup {
        init output3File "1\t2\tHello, World!\t "
    } -body {
        sqawk-tcl \
                -FS \t \
                -output tcl \
                {select a1,a2,a3,a4 from a} $output3File
    } -cleanup {
        uninit
    } -result {{1 2 {Hello, World!} { }}}

    tcltest::test output-3.2 {Tcl output} -setup {
        init output3File "1\t2\tHello, World!\t "
    } -body {
        sqawk-tcl \
                -FS \t \
                -output tcl,dicts=1 \
                {select a1,a2,a3,a4 from a} $output3File
    } -cleanup {
        uninit
    } -result {{a1 1 a2 2 a3 {Hello, World!} a4 { }}}

    tcltest::test output-4.1 {Table output} -constraints {
        utf8
    }  -setup {
        init output4File a,b,c\nd,e,f\ng,h,i
    } -body {
        sqawk-tcl \
                -FS , \
                -output table \
                {select a1,a2,a3 from a} $output4File
    } -cleanup {
        uninit
    } -result ┌─┬─┬─┐\n│a│b│c│\n├─┼─┼─┤\n│d│e│f│\n├─┼─┼─┤\n│g│h│i│\n└─┴─┴─┘

    tcltest::test output-4.2 {Table output} -constraints {
        utf8
    }  -setup {
        init output4File a,b,c\nd,e,f\ng,h,i
    } -body {
        sqawk-tcl \
                -FS , \
                -output {table,alignments=left center right} \
                {select a1,a2,a3 from a} $output4File
    } -cleanup {
        uninit
    } -result ┌─┬─┬─┐\n│a│b│c│\n├─┼─┼─┤\n│d│e│f│\n├─┼─┼─┤\n│g│h│i│\n└─┴─┴─┘

    tcltest::test output-4.3 {Table output} -constraints {
        utf8
    }  -setup {
        init output4File a,b,c\nd,e,f\ng,h,i
    } -body {
        sqawk-tcl \
                -FS , \
                -output {table,alignments=l c r} \
                {select a1,a2,a3 from a} $output4File
    } -cleanup {
        uninit
    } -result ┌─┬─┬─┐\n│a│b│c│\n├─┼─┼─┤\n│d│e│f│\n├─┼─┼─┤\n│g│h│i│\n└─┴─┴─┘

    tcltest::test output-4.4 {Table output} -constraints {
        utf8
    }  -setup {
        init output4File a,b,c\nd,e,f\ng,h,i
    } -body {
        sqawk-tcl \
                -FS , \
                -output {table,align=left center right} \
                {select a1,a2,a3 from a} $output4File
    } -cleanup {
        uninit
    } -result ┌─┬─┬─┐\n│a│b│c│\n├─┼─┼─┤\n│d│e│f│\n├─┼─┼─┤\n│g│h│i│\n└─┴─┴─┘

    tcltest::test output-4.5 {Table output} -setup {
        init output4File a,b,c\nd,e,f\ng,h,i
    } -body {
        sqawk-tcl \
                -FS , \
                -output {table,align=l c r,alignments=l c r} \
                {select a1,a2,a3 from a} $output4File
    } -cleanup {
        uninit
    } -returnCodes 1 \
      -result "can't use the synonym options \"align\" and \"alignments\"\
                    together*" \
      -match glob

    tcltest::test output-5.1 {JSON output} -setup {
        init output4File a,b,c\nd,e,f\ng,h,i
    } -body {
        sqawk-tcl \
                -FS , \
                -output json \
                {select a1,a2,a3 from a} $output4File
    } -cleanup {
        uninit
    } -result [format {[%s,%s,%s]} \
            {{"a1":"a","a2":"b","a3":"c"}} \
            {{"a1":"d","a2":"e","a3":"f"}} \
            {{"a1":"g","a2":"h","a3":"i"}}]

    tcltest::test output-5.2 {JSON output}  -setup {
        init output4File a,b,c\nd,e,f\ng,h,i
    } -body {
        sqawk-tcl \
                -FS , \
                -output json,arrays=1 \
                {select a1,a2,a3 from a} $output4File
    } -cleanup {
        uninit
    } -result {[["a","b","c"],["d","e","f"],["g","h","i"]]}

    tcltest::test trim-1.1 {trim option} -setup {
        init trim1File "   a  \n"
    } -body {
        sqawk-tcl {select a1 from a} $trim1File
    } -cleanup {
        uninit
    } -result {}

    tcltest::test trim-1.2 {trim option} -setup {
        init trim1File "   a  \n"
    } -body {
        sqawk-tcl {select a1 from a} trim=left $trim1File
    } -cleanup {
        uninit
    } -result a

    tcltest::test trim-1.3 {trim option} -setup {
        init trim1File "   a  \n"
    } -body {
        sqawk-tcl {select a1 from a} trim=both $trim1File
    } -cleanup {
        uninit
    } -result a

    tcltest::test a0-1.1 {Verbatim reproduction of input in a0} -setup {
        init filename "test:\n\ttclsh tests.tcl\n\"\{"
    } -body {
        sqawk-tcl {select a0 from a} $filename
    } -cleanup {
        uninit
    } -result "test:\n\ttclsh tests.tcl\n\"\{"

    tcltest::test a0-1.2 {Explicitly enable a0} -setup {
        init filename "test:\n\ttclsh tests.tcl\n\"\{"
    } -body {
        sqawk-tcl {select a0 from a} F0=yes $filename
    } -cleanup {
        uninit
    } -result "test:\n\ttclsh tests.tcl\n\"\{"

    tcltest::test a0-1.3 {Disable a0 and try to select it} -setup {
        init filename "test:\n\ttclsh tests.tcl\n\"\{"
    } -body {
        sqawk-tcl {select a0 from a} F0=off $filename
    } -cleanup {
        uninit
    } -returnCodes 1 -match glob -result {no such column: a0*}

    tcltest::test a0-1.4 {Disable a0 and do unrelated things} -setup {
        init filename "1 2 3\n4 5 6"
    } -body {
        sqawk-tcl {select a1, a2 from a} F0=off $filename
    } -cleanup {
        uninit
    } -result "1 2\n4 5"

    tcltest::test empty-fields-1.1 {Empty fields} -constraints {
        printfInSqlite3
    } -setup {
        init
    } -body {
        sqawk-tcl -FS - {
            select printf("'%s' (%s)(%s)", a0, a1, a2) from a
        } << "0-1\n\na-b\n\nc-d\n"
    } -cleanup {
        uninit
    } -result "'0-1' (0)(1)\n'' ()()\n'a-b' (a)(b)\n'' ()()\n'c-d' (c)(d)"

    tcltest::test empty-fields-1.2 {Empty fields} -constraints {
        printfInSqlite3
    } -setup {
        init
    } -body {
        sqawk-tcl -FS - {
            select printf("'%s' (%s)(%s)", a0, a1, a2) from a
        } << "\n0-1\n\na-b\n"
    } -cleanup {
        uninit
    } -result "'' ()()\n'0-1' (0)(1)\n'' ()()\n'a-b' (a)(b)"

    tcltest::test empty-lines-1.1 {Empty lines} -setup {
        init emptyLines1File \n\n\n\n
    } -body {
        sqawk-tcl {select a1 from a} $emptyLines1File
    } -cleanup {
        uninit
    } -result \n\n\n

    tcltest::test empty-lines-1.2 {Empty lines} -setup {
        init emptyLines1File \n\n\n\n
    } -body {
        sqawk-tcl {select a1 from a} format=csv $emptyLines1File
    } -cleanup {
        uninit
    } -result \n\n\n


    tcltest::test datatypes-1.1 {Datatypes} -setup {
        init datatypes1File "001 a\n002 b\nc"
    } -body {
        sqawk-tcl {select a1,a2 from a} $datatypes1File
    } -cleanup {
        uninit
    } -result "1 a\n2 b\nc "

    tcltest::test datatypes-1.2 {Datatypes} -constraints {
        printfInSqlite3
    } -setup {
        init datatypes1File "001 a\n002 b\nc"
    } -body {
        sqawk-tcl {select printf("%03d",a1),a2 from a} $datatypes1File
    } -cleanup {
        uninit
    } -result "001 a\n002 b\n000 "

    tcltest::test datatypes-1.3 {Datatypes} -setup {
        init datatypes1File "001 a\n002 b\nc"
    } -body {
        sqawk-tcl {select a1,a2 from a} datatypes=real,text $datatypes1File
    } -cleanup {
        uninit
    } -result "1.0 a\n2.0 b\nc "

    tcltest::test datatypes-1.4 {Datatypes}  -setup {
        init datatypes1File "001 a\n002 b\nc"
    } -body {
        sqawk-tcl {select a1,a2 from a} datatypes=null,blob $datatypes1File
    } -cleanup {
        uninit
    } -result "001 a\n002 b\nc "

    tcltest::test datatypes-1.5 {Datatypes}  -setup {
        init datatypes1File "001 a\n002 b\nc"
    } -body {
        sqawk-tcl {select a1,a2 from a} datatypes=text,text $datatypes1File
    } -cleanup {
        uninit
    } -result "001 a\n002 b\nc "

    # NF tests

    tcltest::test nf-1.1 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 0 \
                -MNF crop \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result {{1 0 {A B}} {2 0 {A B C}} {3 0 {A B C D}}}

    tcltest::test nf-1.2 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 1 \
                -MNF crop \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result {{1 1 {A B} A} {2 1 {A B C} A} {3 1 {A B C D} A}}

    tcltest::test nf-1.3 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 2 \
                -MNF crop \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result {{1 2 {A B} A B} {2 2 {A B C} A B} {3 2 {A B C D} A B}}

    tcltest::test nf-1.4 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 3 \
                -MNF crop \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result {{1 2 {A B} A B {}} {2 3 {A B C} A B C} {3 3 {A B C D} A B C}}

    tcltest::test nf-1.5 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 0 \
                -MNF crop \
                -output tcl \
                {select * from a} F0=false $nf1File
    } -cleanup {
        uninit
    } -result {{1 0} {2 0} {3 0}}

    tcltest::test nf-1.6 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 1 \
                -MNF crop \
                -output tcl \
                {select * from a} F0=false $nf1File
    } -cleanup {
        uninit
    } -result {{1 1 A} {2 1 A} {3 1 A}}

    tcltest::test nf-1.7 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 2 \
                -MNF crop \
                -output tcl \
                {select * from a} F0=false $nf1File
    } -cleanup {
        uninit
    } -result {{1 2 A B} {2 2 A B} {3 2 A B}}

    tcltest::test nf-1.8 {NF mode "crop"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 3 \
                -MNF crop \
                -output tcl \
                {select * from a} F0=false $nf1File
    } -cleanup {
        uninit
    } -result {{1 2 A B {}} {2 3 A B C} {3 3 A B C}}

    tcltest::test nf-2.1 {NF mode "crop" 2} -setup {
        init nf2File "A B C D\nA B C\nA B\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 2 \
                -MNF crop \
                -output tcl \
                {select * from a} $nf2File
    } -cleanup {
        uninit
    } -result {{1 2 {A B C D} A B} {2 2 {A B C} A B} {3 2 {A B} A B}}

    tcltest::test nf-2.2 {NF mode "crop" 2}  -setup {
        init nf2File "A B C D\nA B C\nA B\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 3 \
                -MNF crop \
                -output tcl \
                {select * from a} $nf2File
    } -cleanup {
        uninit
    } -result {{1 3 {A B C D} A B C} {2 3 {A B C} A B C} {3 2 {A B} A B {}}}

    tcltest::test nf-2.3 {NF mode "crop" 2} -setup {
        init nf2File "A B C D\nA B C\nA B\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 4 \
                -MNF crop \
                -output tcl \
                {select * from a} $nf2File
    } -cleanup {
        uninit
    } -result \
        {{1 4 {A B C D} A B C D} {2 3 {A B C} A B C {}} {3 2 {A B} A B {} {}}}

    tcltest::test nf-3.1 {NF mode "expand"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 0 \
                -MNF expand \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result \
        {{1 2 {A B} A B {} {}} {2 3 {A B C} A B C {}} {3 4 {A B C D} A B C D}}

    tcltest::test nf-3.2 {NF mode "expand"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 1 \
                -MNF expand \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result \
        {{1 2 {A B} A B {} {}} {2 3 {A B C} A B C {}} {3 4 {A B C D} A B C D}}

    tcltest::test nf-3.3 {NF mode "expand"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 2 \
                -MNF expand \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result \
        {{1 2 {A B} A B {} {}} {2 3 {A B C} A B C {}} {3 4 {A B C D} A B C D}}

    tcltest::test nf-3.4 {NF mode "expand"} -setup {
        init nf1File "A B\nA B C\nA B C D\n"
    } -body {
        sqawk-tcl \
                -FS " " \
                -NF 3 \
                -MNF expand \
                -output tcl \
                {select * from a} $nf1File
    } -cleanup {
        uninit
    } -result \
        {{1 2 {A B} A B {} {}} {2 3 {A B C} A B C {}} {3 4 {A B C D} A B C D}}

    tcltest::test nf-4.1 {NF mode "error"} -setup {
        set content {}
        append content "A B\n"
        append content "A B C\n"
        init filename $content
        unset content
    } -body {
        sqawk-tcl \
            -FS " " \
            -NF 2 \
            -MNF error \
            -output tcl \
            {select * from a} $filename
    } -cleanup {
        uninit
    } -returnCodes 1 -match glob -result {table a has no column named a3*}

    tcltest::test nf-5.1 {invalid NF mode} -setup {
        set content {}
        append content "A B\n"
        append content "A B C\n"
        init filename $content
        unset content
    } -body {
        set content {}
        append content "A B\n"
        append content "A B C\n"
        set filename [make-temp-file $content]
        sqawk-tcl \
            -FS " " \
            -NF 2 \
            -MNF foo \
            -output tcl \
            {select * from a} $filename
    } -cleanup {
        uninit
    } -returnCodes 1 -match glob -result {invalid MNF value: "foo"*}

    # Tabulate tests

    proc tabulate-tcl args {
        exec [info nameofexecutable] lib/tabulate.tcl {*}$args
    }

    proc tabulate-jim args {
        exec jimsh lib/tabulate.tcl {*}$args
    }

    proc tabulate-test tabulateCmd {
        set result {}
        lappend result [$tabulateCmd << "a b c\nd e f\n"]
        lappend result [$tabulateCmd -FS , << "a,b,c\nd,e,f\n"]
        lappend result [$tabulateCmd -margins 1 << "a b c\nd e f\n"]
        lappend result [$tabulateCmd -alignments {left center right} << \
                "hello space world\nfoo bar baz\n"]
        return \n[join $result \n]
    }

    set tabulateAppTestOutput {
┌─┬─┬─┐
│a│b│c│
├─┼─┼─┤
│d│e│f│
└─┴─┴─┘
┌─┬─┬─┐
│a│b│c│
├─┼─┼─┤
│d│e│f│
└─┴─┴─┘
┌───┬───┬───┐
│ a │ b │ c │
├───┼───┼───┤
│ d │ e │ f │
└───┴───┴───┘
┌─────┬─────┬─────┐
│hello│space│world│
├─────┼─────┼─────┤
│foo  │ bar │  baz│
└─────┴─────┴─────┘}

    tcltest::test tabulate-1.1 {Tabulate as application} -constraints {
        utf8
    } -setup {
        init
    } -body {
        return [tabulate-test tabulate-tcl]
    } -cleanup {
        uninit
    } -result $tabulateAppTestOutput 

    tcltest::test tabulate-1.2 {Tabulate as application with Jim Tcl} \
            -constraints {
        jimsh
        utf8
    } -setup {
        init
    } -body {
        return [tabulate-test tabulate-jim]
    } -cleanup {
        uninit
    } -result $tabulateAppTestOutput 

    tcltest::test tabulate-2.1 {Tabulate as library} -constraints {
        utf8
    } -setup {
        init
    } -body {
        source -encoding utf-8 [file join $path lib tabulate.tcl]
        return \n[::tabulate::tabulate -data {{a b c} {d e f}}]\n
    } -cleanup {
        uninit
    } -result {
┌─┬─┬─┐
│a│b│c│
├─┼─┼─┤
│d│e│f│
└─┴─┴─┘
}

    tcltest::test tabulate-2.2 {Tabulate as library} -setup {
        init
    } -body {
        source -encoding utf-8 [file join $path lib tabulate.tcl]
        return  \n[::tabulate::tabulate \
                -data {{a b c} {d e f}} \
                -style $::tabulate::style::loFi]\n
    } -cleanup {
        uninit
    } -result {
+-+-+-+
|a|b|c|
+-+-+-+
|d|e|f|
+-+-+-+
}

    tcltest::test tabulate-2.3 {Tabulate as library} -constraints {
        utf8
    } -setup {
        init
    } -body {
        source -encoding utf-8 [file join $path lib tabulate.tcl]
        return \n[::tabulate::tabulate \
                -margins 1 \
                -data {{a b c} {d e f}}]\n
    } -cleanup {
        uninit
    } -result {
┌───┬───┬───┐
│ a │ b │ c │
├───┼───┼───┤
│ d │ e │ f │
└───┴───┴───┘
}

    tcltest::test tabulate-2.4 {Tabulate as library} -constraints {
        utf8
    } -setup {
        init
    } -body {
        source -encoding utf-8 [file join $path lib tabulate.tcl]
        return \n[::tabulate::tabulate \
                -alignments {left center right} \
                -data {{hello space world} {foo bar baz}}]\n
    } -cleanup {
        uninit
    } -result {
┌─────┬─────┬─────┐
│hello│space│world│
├─────┼─────┼─────┤
│foo  │ bar │  baz│
└─────┴─────┴─────┘
}

    tcltest::test tabulate-2.5 {Tabulate as library} -constraints {
        utf8
    } -setup {
        init
    } -body {
        source -encoding utf-8 [file join $path lib tabulate.tcl]
        return \n[::tabulate::tabulate \
                -align {left center right} \
                -data {{hello space world} {foo bar baz}}]\n
    } -cleanup {
        uninit
    } -result {
┌─────┬─────┬─────┐
│hello│space│world│
├─────┼─────┼─────┤
│foo  │ bar │  baz│
└─────┴─────┴─────┘
}

    tcltest::test tabulate-2.6 {Tabulate as library} -setup {
        init
    } -body {
        source -encoding utf-8 [file join $path lib tabulate.tcl]
        return \n[::tabulate::tabulate \
                -alignments {left center right} \
                -align {left center right} \
                -data {{hello space world} {foo bar baz}}]\n
    } -cleanup {
        uninit
    } -returnCodes 1 \
      -result {can't use the flags "-alignments", "-align" together}

    tcltest::test tabulate-3.0 {format-flag-synonyms} -setup {
        init 
    } -body {
        set result {}
        lappend result [::tabulate::options::format-flag-synonyms -foo]
        lappend result [::tabulate::options::format-flag-synonyms {-foo -bar}]
        lappend result [::tabulate::options::format-flag-synonyms \
                {-foo -bar -baz -quux}]
        return $result
    } -cleanup {
        unset result
        uninit
    } -result {{"-foo"} {"-foo" ("-bar")} {"-foo" ("-bar", "-baz", "-quux")}}

    # Exit with a nonzero status if there are failed tests.
    set failed [expr {$tcltest::numTests(Failed) > 0}]

    tcltest::cleanupTests
    if {$failed} {
        exit 1
    }
}
