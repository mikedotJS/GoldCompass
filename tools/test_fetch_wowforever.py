"""Parser test on 5 saved real rows: python3 -m unittest tools/test_fetch_wowforever.py (from the addon folder)."""
import importlib.util, pathlib, unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fetch_wowforever", HERE / "fetch-wowforever.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
PAGE = (HERE.parent / "spec/fixtures/wowforever_leatherworking_rows.html").read_text(encoding="utf-8")


class Parse(unittest.TestCase):
    def setUp(self):
        self.rows = {r["name"]: r for r in mod.parse_rows(PAGE)}

    def test_five_rows(self):
        self.assertEqual(5, len(self.rows))

    def test_trainer_row(self):
        r = self.rows["Small Leather Ammo Pouch"]
        self.assertEqual((7279, 25, (25, 55, 70, 85), True, 100), (r["item"], r["learn"], r["thresholds"], r["trainer"], r["cost"]))

    def test_vendor_and_trainer_row(self):
        r = self.rows["Moonglow Boots"]
        self.assertTrue(r["trainer"])
        self.assertEqual(500, r["cost"])
        self.assertEqual("Granny Finespindle (Ironforge)", r["vendor"])

    def test_drop_row_is_not_trainer_taught(self):
        r = self.rows["Fine Leather Boots"]
        self.assertFalse(r["trainer"])
        self.assertIsNone(r["cost"])

    def test_journeyman_recipe(self):
        r = self.rows["Fine Leather Belt"]
        self.assertEqual((55, 300), (r["learn"], r["cost"]))
        self.assertEqual("Journeyman", mod.rank_of(r["learn"]))

    def test_known_from_the_start(self):
        self.assertTrue(self.rows["Handstitched Leather Boots"]["start"])

    def test_ranks_and_money(self):
        self.assertEqual(["Apprentice", "Journeyman", "Expert", "Artisan"], [mod.rank_of(n) for n in (49, 50, 125, 200)])
        self.assertEqual(15050, mod.money("1g 50s 50c"))

    def test_build(self):
        self.assertEqual(("1.60.1.70862", "7 November 2026"), mod.page_build("<p>build 1.60.1.70862 · 7 November 2026</p>"))


if __name__ == "__main__":
    unittest.main()
