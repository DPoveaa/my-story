extends SceneTree

const TestM1Script = preload("res://tests/test_m1.gd")
const TestM1_1Script = preload("res://tests/test_m1_1.gd")
const TestM2Script = preload("res://tests/test_m2.gd")
const TestM2_1Script = preload("res://tests/test_m2_1.gd")
const TestM2_2Script = preload("res://tests/test_m2_2.gd")
const TestM2_3Script = preload("res://tests/test_m2_3.gd")
const TestMortarBrushScript = preload("res://tests/test_mortar_brush.gd")
const TestM3Script = preload("res://tests/test_m3.gd")

func _init() -> void:
	print("Initializing test runner...")
	var suite_brush = TestMortarBrushScript.new()
	var success_brush: bool = suite_brush.run_all()

	var suite1 = TestM1Script.new()
	var success1: bool = suite1.run_all()

	var suite2 = TestM1_1Script.new()
	var success2: bool = suite2.run_all()

	var suite3 = TestM2Script.new()
	var success3: bool = suite3.run_all()

	var suite4 = TestM2_1Script.new()
	var success4: bool = suite4.run_all()

	var suite5 = TestM2_2Script.new()
	var success5: bool = suite5.run_all()

	var suite6 = TestM2_3Script.new()
	var success6: bool = suite6.run_all()

	var suite7 = TestM3Script.new()
	var success7: bool = suite7.run_all()

	if success_brush and success1 and success2 and success3 and success4 and success5 and success6 and success7:
		print("==================================================")
		print("ALL MORTAR BRUSH, MILESTONE 1, 1.1, 2, 2.1, 2.2, 2.3 AND M3 TESTS PASSED SUCCESSFULLY!")
		print("==================================================")
		quit(0)
	else:
		printerr("SOME TESTS FAILED!")
		quit(1)

