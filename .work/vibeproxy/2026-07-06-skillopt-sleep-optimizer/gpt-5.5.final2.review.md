BLOCK: remaining concrete sleep-loop correctness issue found.

`CoreAgentSkillSleepOptimizer.run` does not prevalidate proposal scores / heldout suite IDs before mutating skills, even though `CoreAgentSkillOptimizer.propose` does validate them. This can make a sleep run partially mutate state and then throw later, leaving no report and a half-applied run.

Concrete scenario:

1. Request has two proposals with unique IDs.
2. First proposal is valid and accepted, mutating skill version `1 -> 2`.
3. Second proposal has an invalid validation score, e.g. `score: 2.0` or non-finite baseline/score.
4. Sleep loop reaches `optimizer.propose`, which calls `validateScores` and throws `invalidValidationScore`.
5. The run aborts after the first mutation has already been saved.

This is inconsistent with the duplicate-proposal preflight behavior, which correctly validates before mutation. For the sleep/recursive optimization loop, malformed validation input should either be rejected deterministically as an entry or preflighted before any accepted proposal is saved.
