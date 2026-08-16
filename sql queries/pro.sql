-- final
-- first we need to create database if not exists
CREATE DATABASE IF NOT EXISTS project;
-- we need to use that database name
USE project;

-- ============================================================
-- UPDATED SCHEMA — matches the enriched *_updated.csv files
-- Changes from original schema are called out in comments
-- ============================================================

-- Table 1: Job Department
CREATE TABLE JobDepartment (
    Job_ID INT PRIMARY KEY,
    jobdept VARCHAR(50),
    name VARCHAR(100),
    description TEXT,
    salaryrange VARCHAR(50),
    role_level VARCHAR(20)                 -- NEW: Junior / Mid / Senior / Executive;
);                                          --      parsed from job title, enables peer-group
                                             --      comparison beyond exact job title
select * from JobDepartment;

-- Table 2: Salary/Bonus
CREATE TABLE SalaryBonus (
    salary_ID INT PRIMARY KEY,
    Job_ID INT,
    amount DECIMAL(10,2),
    annual DECIMAL(10,2),
    bonus DECIMAL(10,2),
    bonus_pct DECIMAL(5,2),                -- NEW: bonus as % of annual salary,
                                            --      lets you compare bonus proportionality
                                            --      across departments directly
    CONSTRAINT fk_salary_job FOREIGN KEY (Job_ID) REFERENCES JobDepartment(Job_ID)
        ON DELETE CASCADE ON UPDATE CASCADE
);
select * from SalaryBonus;

-- Table 3: Employee
CREATE TABLE Employee (
    emp_ID INT PRIMARY KEY,
    firstname VARCHAR(50),
    lastname VARCHAR(50),
    gender VARCHAR(10),
    age INT,
    contact_add VARCHAR(100),
    emp_email VARCHAR(100) UNIQUE,
    emp_pass VARCHAR(50),
    Job_ID INT,
    hire_date DATE,                        -- NEW: date employee started, drives tenure calc
    tenure_years DECIMAL(4,1),             -- NEW: years of experience as of ref date;
                                            --      core input for stagnation-risk analysis
    CONSTRAINT fk_employee_job FOREIGN KEY (Job_ID)
        REFERENCES JobDepartment(Job_ID)
        ON DELETE SET NULL
        ON UPDATE CASCADE
);
select * from Employee;

-- Table 4: Qualification
CREATE TABLE Qualification (
    QualID INT PRIMARY KEY,
    Emp_ID INT,
    Position VARCHAR(50),
    Requirements VARCHAR(255),
    Date_In DATE,
    degree_level VARCHAR(30),              -- NEW: Bachelor's / Master's / Certification-Other,
                                            --      standardized from Requirements text to
                                            --      flag qualification-vs-role mismatches
    CONSTRAINT fk_qualification_emp FOREIGN KEY (Emp_ID)
        REFERENCES Employee(emp_ID)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);
select * from Qualification;

-- Table 5: Leaves
-- NOTE: now holds multiple leave events per employee (2-9 rows/employee across 2024)
-- instead of a single snapshot row, so leave frequency/behavior can actually be measured
CREATE TABLE Leaves (
    leave_ID INT PRIMARY KEY,
    emp_ID INT,
    date DATE,
    reason TEXT,
    leave_days INT,                        -- NEW: length of each leave event, enables
                                            --      total-days-taken and frequency metrics
    CONSTRAINT fk_leave_emp FOREIGN KEY (emp_ID) REFERENCES Employee(emp_ID)
        ON DELETE CASCADE ON UPDATE CASCADE
);
select * from Leaves;

-- Table 6: Payroll
-- NOTE: now holds 12 monthly records per employee (salary history for 2024) instead of
-- a single April snapshot, so raises / flat pay over time can be detected.
-- leave_ID FK was REMOVED: payroll rows are no longer tied to a specific leave record
-- (monthly payroll isn't naturally 1:1 with a leave event in the enriched data).
CREATE TABLE Payroll (
    payroll_ID INT PRIMARY KEY,
    emp_ID INT,
    job_ID INT,
    salary_ID INT,
    date DATE,
    report TEXT,
    total_amount DECIMAL(10,2),
    raise_applied CHAR(1),                 -- NEW: 'Y'/'N' flag, the specific month a raise
                                            --      landed — direct input for a stagnation flag
    CONSTRAINT fk_payroll_emp FOREIGN KEY (emp_ID) REFERENCES Employee(emp_ID)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_payroll_job FOREIGN KEY (job_ID) REFERENCES JobDepartment(Job_ID)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_payroll_salary FOREIGN KEY (salary_ID) REFERENCES SalaryBonus(salary_ID)
        ON DELETE CASCADE ON UPDATE CASCADE
);
select * from Payroll;


# ============================================================
# PROJECT: EMPLOYEE CAREER & WORKFORCE RISK INTELLIGENCE
# BUSINESS PROBLEM:
# Identify employees whose career progression and compensation
# appear inconsistent with their experience, qualifications,
# position, and comparable peer groups.
# ============================================================

# ============================================================
# PROJECT: EMPLOYEE CAREER & WORKFORCE INTELLIGENCE
# OBJECTIVE:
# Identify employees whose career progression and compensation
# appear inconsistent with their experience and peer group.
# ============================================================
-- EmployeeProfile view
CREATE OR REPLACE VIEW EmployeeProfile AS
SELECT e.emp_ID, e.firstname, e.lastname, e.tenure_years,
       jd.jobdept, jd.role_level, q.degree_level,
       sb.amount AS monthly_salary, sb.bonus_pct
FROM Employee e
JOIN JobDepartment jd ON e.Job_ID = jd.Job_ID
LEFT JOIN Qualification q ON e.emp_ID = q.Emp_ID
LEFT JOIN SalaryBonus sb ON e.Job_ID = sb.Job_ID;

-- 1. Stagnation: 5+ yrs, still Junior/Mid
SELECT * FROM EmployeeProfile
WHERE tenure_years >= 5 AND role_level IN ('Junior','Mid');

-- 2. Underpaid vs dept avg
SELECT emp_ID, firstname, lastname, jobdept, monthly_salary
FROM EmployeeProfile ep
WHERE monthly_salary < (SELECT AVG(monthly_salary) FROM EmployeeProfile WHERE jobdept = ep.jobdept);

-- 3. Dept salary disparity
SELECT jobdept, MIN(monthly_salary) min_sal, MAX(monthly_salary) max_sal,
       MAX(monthly_salary)-MIN(monthly_salary) AS gap
FROM EmployeeProfile GROUP BY jobdept ORDER BY gap DESC;

-- 4. Qualification mismatch
SELECT emp_ID, firstname, lastname, role_level, degree_level
FROM EmployeeProfile
WHERE (degree_level='Master''s' AND role_level IN ('Junior','Mid'))
   OR (degree_level='Certification/Other' AND role_level IN ('Senior','Executive'));

-- 5. Leave totals
SELECT emp_ID, COUNT(*) leaves, SUM(leave_days) total_days
FROM Leaves GROUP BY emp_ID ORDER BY total_days DESC;

-- 6. Risk score
SELECT ep.emp_ID, ep.firstname, ep.lastname, ep.jobdept, ep.role_level,
  (CASE WHEN ep.tenure_years>=5 AND ep.role_level IN ('Junior','Mid') THEN 1 ELSE
  0 END) +
  (CASE WHEN ep.monthly_salary < da.avg_sal THEN 1 ELSE 0 END) +
  (CASE WHEN nr.emp_ID IS NOT NULL THEN 1 ELSE 0 END) AS risk_score
FROM EmployeeProfile ep
JOIN (SELECT jobdept, AVG(monthly_salary) avg_sal FROM EmployeeProfile GROUP BY jobdept) da
  ON ep.jobdept = da.jobdept
LEFT JOIN (SELECT emp_ID FROM Payroll GROUP BY emp_ID
  HAVING SUM(CASE WHEN raise_applied='Y' THEN 1 ELSE 0 END)=0) nr
  ON ep.emp_ID = nr.emp_ID
ORDER BY risk_score DESC;
