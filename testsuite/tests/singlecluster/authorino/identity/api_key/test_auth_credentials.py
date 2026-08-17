============================= test session starts ==============================
platform linux -- Python 3.11.13, pytest-9.1.1, pluggy-1.6.0
rootdir: /root/testsuite
configfile: pyproject.toml
plugins: anyio-4.14.2, metadata-3.1.1, xdist-3.8.0, rerunfailures-16.4, html-4.2.0
collected 611 items / 2 errors / 609 deselected / 2 selected

==================================== ERRORS ====================================
_____ ERROR collecting testsuite/tests/singlecluster/gateway/test_basic.py _____
../.cache/pypoetry/virtualenvs/kuadrant-testsuite-omvbjoNk-py3.11/lib/python3.11/site-packages/_pytest/python.py:508: in importtestmodule
    mod = import_path(
../.cache/pypoetry/virtualenvs/kuadrant-testsuite-omvbjoNk-py3.11/lib/python3.11/site-packages/_pytest/pathlib.py:596: in import_path
    importlib.import_module(module_name)
/usr/lib64/python3.11/importlib/__init__.py:126: in import_module
    return _bootstrap._gcd_import(name[level:], package, level)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
<frozen importlib._bootstrap>:1204: in _gcd_import
    ???
<frozen importlib._bootstrap>:1176: in _find_and_load
    ???
<frozen importlib._bootstrap>:1147: in _find_and_load_unlocked
    ???
<frozen importlib._bootstrap>:690: in _load_unlocked
    ???
../.cache/pypoetry/virtualenvs/kuadrant-testsuite-omvbjoNk-py3.11/lib/python3.11/site-packages/_pytest/assertion/rewrite.py:179: in exec_module
    source_stat, co = _rewrite_test(fn, self.config)
                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
../.cache/pypoetry/virtualenvs/kuadrant-testsuite-omvbjoNk-py3.11/lib/python3.11/site-packages/_pytest/assertion/rewrite.py:348: in _rewrite_test
    tree = ast.parse(source, filename=strfn)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
/usr/lib64/python3.11/ast.py:50: in parse
    return compile(source, filename, mode, flags,
E     File "/root/testsuite/testsuite/tests/singlecluster/gateway/test_basic.py", line 8
E       ============================ no tests ran in 0.01s =============================
E                                                       ^
E   SyntaxError: invalid decimal literal
_______ ERROR collecting testsuite/tests/singlecluster/ui/console_plugin _______
/usr/lib64/python3.11/importlib/__init__.py:126: in import_module
    return _bootstrap._gcd_import(name[level:], package, level)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
<frozen importlib._bootstrap>:1204: in _gcd_import
    ???
<frozen importlib._bootstrap>:1176: in _find_and_load
    ???
<frozen importlib._bootstrap>:1147: in _find_and_load_unlocked
    ???
<frozen importlib._bootstrap>:690: in _load_unlocked
    ???
../.cache/pypoetry/virtualenvs/kuadrant-testsuite-omvbjoNk-py3.11/lib/python3.11/site-packages/_pytest/assertion/rewrite.py:188: in exec_module
    exec(co, module.__dict__)
testsuite/tests/singlecluster/ui/console_plugin/conftest.py:10: in <module>
    from testsuite.page_objects.nav_bar import NavBar
testsuite/page_objects/nav_bar.py:3: in <module>
    from testsuite.page_objects.navigator import step, Navigable
testsuite/page_objects/navigator.py:8: in <module>
    from playwright.sync_api import Page, TimeoutError as PlaywrightTimeoutError, Error as PlaywrightError
E   ModuleNotFoundError: No module named 'playwright'
=========================== short test summary info ============================
ERROR testsuite/tests/singlecluster/gateway/test_basic.py
ERROR testsuite/tests/singlecluster/ui/console_plugin - ModuleNotFoundError: ...
!!!!!!!!!!!!!!!!!!! Interrupted: 2 errors during collection !!!!!!!!!!!!!!!!!!!!
====================== 609 deselected, 2 errors in 1.84s =======================
