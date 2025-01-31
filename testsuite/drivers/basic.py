import glob
import os

from e3.testsuite.result import TestStatus

from drivers import ALSTestDriver


class JsonTestDriver(ALSTestDriver):
    """ Each test should have:
          - a test.yaml containing
                title: '<test name>'

          - a number of test drivers, in .json files.
    """

    def run(self, previous_values, slot):
        # Check whether the test should be skipped
        if self.should_skip():
            return False

        # The working directory
        wd = self.test_env["working_dir"]

        output = ""

        status = TestStatus.PASS

        for json in glob.glob(os.path.join(wd, "*.json")):
            process = self.run_and_log(
                [self.env.tester_run, json],
                cwd=wd,
                env={
                    "ALS": self.env.als,
                    "ALS_HOME": self.env.als_home,
                    "ALS_WAIT_FACTOR": str(self.env.wait_factor),
                },
                ignore_environ=False,
            )
            output += process.out

            if process.status:
                # Nonzero status?
                status = TestStatus.FAIL
                break

        self.result.set_status(status)
        if output:
            # If there's an output, capture it as log
            self.result.log = output

        self.push_result()
